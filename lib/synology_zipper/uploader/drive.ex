defmodule SynologyZipper.Uploader.Drive do
  @moduledoc """
  Pure Drive v3 operations used by the uploader. Every call goes
  through `google_api_drive`, which is Tesla-based; tests stub it
  with `Tesla.Mock`.

  **Invariants:**

    1. Never touch anything in Drive outside the configured folder.
       - `list_for_upload/3` scopes by `name='<month>.zip' and '<folder>' in parents`.
       - `create/3` sets `parents=[folder_id]`.
       - `delete/2` is only ever called on a file we *just* created
         ourselves when the post-create md5 doesn't match.
    2. Shared-Drive safe: `supportsAllDrives: true` on every call;
       `includeItemsFromAllDrives: true` on list.
    3. Idempotency via orphan adoption: before create, list. Exactly
       one match + md5 equal -> adopt. Mismatch -> `:orphan_md5_mismatch`.
       Multiple -> `:ambiguous_orphan`. These are permanent errors.
    4. Local md5 is computed by streaming the zip in 1 MiB chunks;
       the upload body is streamed directly from disk via Tesla's
       multipart file part. Neither path holds the full zip in memory.
  """

  alias GoogleApi.Drive.V3.Api.Files
  alias GoogleApi.Drive.V3.Model.{File, FileList}
  alias SynologyZipper.Uploader.{Job, Result}

  @pubsub SynologyZipper.PubSub

  # 1 MiB read chunks — coarse enough that the Stream.transform overhead
  # is negligible at 100 GB upload sizes, fine enough that a broadcast
  # fires reasonably often (~once per second on a 10 MB/s uplink).
  @upload_chunk 1_048_576

  # Floor for progress broadcasts: 1.5s between events, or every time
  # we cross a 5% threshold, whichever comes first. Also always fires
  # the terminal "100% done" event so the UI clears cleanly.
  @progress_throttle_ms 1_500
  @progress_pct_step 5

  @typedoc "A ready-to-use `Tesla.Client` — test or prod."
  @type conn :: Tesla.Env.client()

  @typedoc "Terminal errors the runner inspects to classify retry-or-fail."
  @type error ::
          {:drive_error, code :: integer(), message :: String.t()}
          | {:md5_mismatch, local :: String.t(), drive :: String.t()}
          | {:orphan_md5_mismatch,
             %{file_id: String.t(), local: String.t(), drive: String.t()}}
          | {:ambiguous_orphan, [String.t()]}
          | {:local_zip_missing, String.t()}
          | {:local_zip_read, String.t(), term()}
          | {:transport, term()}

  # 1 MiB streaming chunk for md5 hashing. Keeps peak RAM flat
  # regardless of zip size.
  @md5_chunk 1_048_576

  @doc """
  Execute one upload job.

  Sequence:
    1. List the target folder for `'<month>.zip'`. Zero → continue.
       One match + matching md5 → adopt that file's id and return.
       One match, mismatch md5 → `{:error, {:orphan_md5_mismatch, …}}`.
       Multiple matches → `{:error, {:ambiguous_orphan, …}}`.
    2. Stream-compute the local zip's md5.
    3. POST a streamed multipart upload (file part read from disk)
       into `parents=[folder_id]` with `supportsAllDrives=true`,
       asking Drive for `id, md5Checksum, size`.
    4. Compare Drive's md5 to ours; on mismatch DELETE the created file
       (the only destructive Drive call in the entire app) and return
       `{:error, {:md5_mismatch, …}}`.
  """
  @spec upload(conn, Job.t()) :: {:ok, Result.t()} | {:error, error()}
  def upload(conn, %Job{} = job) do
    name = "#{job.month}.zip"

    with {:ok, existing} <- list_for_upload(conn, job.drive_folder_id, name),
         :continue <- decide(existing) do
      do_upload(conn, job, name)
    else
      {:adopt, %File{} = f} ->
        adopt(job, f)

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # List + decide
  # ---------------------------------------------------------------------------

  @doc false
  def list_for_upload(conn, folder_id, name) do
    q =
      "name = '#{escape_q(name)}' and '#{escape_q(folder_id)}' in parents and trashed = false"

    case Files.drive_files_list(conn,
           q: q,
           fields: "files(id, name, md5Checksum, size)",
           supportsAllDrives: true,
           includeItemsFromAllDrives: true
         ) do
      {:ok, %FileList{files: files}} ->
        {:ok, files || []}

      {:error, err} ->
        {:error, classify_drive_error(err)}
    end
  end

  # Drive query-string literal escaping: backslash first, then single
  # quote. Order matters — escape `\` before `'` or the replacement
  # backslashes get re-escaped.
  defp escape_q(s) when is_binary(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  defp decide([]), do: :continue
  defp decide([%File{} = one]), do: {:adopt, one}

  defp decide(many) when is_list(many) do
    ids = Enum.map(many, & &1.id)
    {:error, {:ambiguous_orphan, ids}}
  end

  # ---------------------------------------------------------------------------
  # Adopt
  # ---------------------------------------------------------------------------

  defp adopt(%Job{zip_path: path}, %File{id: id, md5Checksum: drive_md5, size: size}) do
    case file_md5(path) do
      {:ok, local_md5} ->
        if is_binary(drive_md5) and drive_md5 == local_md5 do
          {:ok,
           %Result{
             drive_file_id: id,
             bytes: size_to_int(size),
             duration_ms: 0
           }}
        else
          {:error,
           {:orphan_md5_mismatch, %{file_id: id, local: local_md5, drive: drive_md5 || ""}}}
        end

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Create + md5 verify + delete-on-mismatch
  # ---------------------------------------------------------------------------

  defp do_upload(conn, %Job{zip_path: path, drive_folder_id: folder_id} = job, name) do
    with {:ok, local_md5} <- file_md5(path),
         {:ok, total_size} <- file_size(path) do
      start = System.monotonic_time(:millisecond)

      meta_json =
        Jason.encode!(%{
          name: name,
          mimeType: "application/zip",
          parents: [folder_id]
        })

      # Fire the initial 0% event so the UI can surface "uploading X"
      # with the total size before the first chunk lands on the wire.
      broadcast_progress(job.source_name, job.month, 0, total_size)

      case post_multipart(conn, job, meta_json, path, total_size) do
        {:ok, %Tesla.Env{status: 200, body: body}} ->
          # One final 100% so the UI snaps to "done" even if the last
          # throttled broadcast landed a few seconds before the close.
          broadcast_progress(job.source_name, job.month, total_size, total_size)

          elapsed = System.monotonic_time(:millisecond) - start

          case parse_created_file(body) do
            %File{} = created -> verify_and_finalise(conn, created, local_md5, elapsed)
            nil -> {:error, {:drive_error, 200, "unparseable create response"}}
          end

        {:ok, %Tesla.Env{} = env} ->
          {:error, classify_drive_error(env)}

        {:error, reason} ->
          {:error, classify_drive_error({:error, reason})}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming multipart POST
  # ---------------------------------------------------------------------------
  #
  # `google_api_drive`'s `drive_files_create_simple` builds its own
  # Tesla.Multipart internally with `Multipart.add_file/3`, which
  # streams the file but gives us zero per-chunk observability. To
  # surface an upload % to the UI we build the multipart/related body
  # ourselves so we control the file stream and can wrap it in a
  # `Stream.transform` that counts bytes and throttles a PubSub
  # broadcast.
  #
  # Body shape (multipart/related per Drive docs):
  #
  #   --<boundary>\r\n
  #   Content-Type: application/json; charset=UTF-8\r\n
  #   \r\n
  #   {metadata JSON}\r\n
  #   --<boundary>\r\n
  #   Content-Type: application/zip\r\n
  #   \r\n
  #   {file bytes}\r\n
  #   --<boundary>--\r\n
  #
  # We precompute `content-length` (metadata JSON + header overhead +
  # file size) so Finch sends the request framed instead of falling
  # back to chunked-transfer-encoding — Drive seems happier with the
  # framed form on large uploads.
  defp post_multipart(conn, %Job{} = job, meta_json, path, file_size) do
    boundary = "SynZip-" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

    metadata_header = "--#{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
    metadata_tail = "\r\n"
    file_header = "--#{boundary}\r\nContent-Type: application/zip\r\n\r\n"
    closer = "\r\n--#{boundary}--\r\n"

    content_length =
      byte_size(metadata_header) +
        byte_size(meta_json) +
        byte_size(metadata_tail) +
        byte_size(file_header) +
        file_size +
        byte_size(closer)

    body_stream =
      Stream.concat([
        [metadata_header, meta_json, metadata_tail, file_header],
        counting_file_stream(path, file_size, job.source_name, job.month),
        [closer]
      ])

    headers = [
      {"content-type", "multipart/related; boundary=#{boundary}"},
      {"content-length", Integer.to_string(content_length)}
    ]

    # Pass query as a keyword list so `Tesla.Env.url` stays the plain
    # endpoint; `Tesla.Mock`'s URL matcher compares `env.url` literally
    # and everything in `env.query` is held separate until the adapter
    # builds the final wire URL.
    Tesla.post(
      conn,
      "https://www.googleapis.com/upload/drive/v3/files",
      body_stream,
      headers: headers,
      query: [
        uploadType: "multipart",
        supportsAllDrives: true,
        fields: "id,md5Checksum,size"
      ]
    )
  end

  # Wraps the raw file stream in a byte counter that fires throttled
  # `{:upload_progress, source, month, bytes, total}` broadcasts on
  # the per-source PubSub topic.
  defp counting_file_stream(path, total_size, source_name, month) do
    # 3-arity `File.stream!` kept for Elixir < 1.16 compatibility —
    # matches the existing md5 stream in this module. The [] modes
    # default to `:raw` + `:read_ahead` which we want.
    Stream.transform(
      Elixir.File.stream!(path, [], @upload_chunk),
      fn -> {0, 0, 0} end,
      fn chunk, {bytes, last_ms, last_pct} ->
        new_bytes = bytes + byte_size(chunk)
        now = System.monotonic_time(:millisecond)
        pct = progress_pct(new_bytes, total_size)

        if should_broadcast?(last_ms, now, last_pct, pct) do
          broadcast_progress(source_name, month, new_bytes, total_size)
          {[chunk], {new_bytes, now, pct}}
        else
          {[chunk], {new_bytes, last_ms, last_pct}}
        end
      end,
      fn _acc -> :ok end
    )
  end

  defp progress_pct(_bytes, 0), do: 0

  defp progress_pct(bytes, total) do
    min(div(bytes * 100, total), 100)
  end

  defp should_broadcast?(last_ms, now, last_pct, pct) do
    now - last_ms >= @progress_throttle_ms or pct - last_pct >= @progress_pct_step
  end

  defp broadcast_progress(source_name, month, bytes, total) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "source:#{source_name}",
      {:upload_progress, source_name, month, bytes, total}
    )
  end

  defp parse_created_file(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"id" => id} = m} ->
        %File{id: id, md5Checksum: m["md5Checksum"], size: m["size"]}

      _ ->
        nil
    end
  end

  defp parse_created_file(%{"id" => id} = m) do
    %File{id: id, md5Checksum: m["md5Checksum"], size: m["size"]}
  end

  defp parse_created_file(%File{} = f), do: f
  defp parse_created_file(_), do: nil

  defp file_size(path) do
    case Elixir.File.stat(path) do
      {:ok, %Elixir.File.Stat{size: size}} -> {:ok, size}
      {:error, :enoent} -> {:error, {:local_zip_missing, path}}
      {:error, reason} -> {:error, {:local_zip_read, path, reason}}
    end
  end

  defp verify_and_finalise(conn, %File{id: id} = created, local_md5, elapsed) do
    drive_md5 = created.md5Checksum

    cond do
      is_binary(drive_md5) and drive_md5 != local_md5 ->
        # Only destructive Drive call in the app — on a file we just made.
        _ = Files.drive_files_delete(conn, id, supportsAllDrives: true)
        {:error, {:md5_mismatch, local_md5, drive_md5}}

      true ->
        {:ok,
         %Result{
           drive_file_id: id,
           bytes: size_to_int(created.size),
           duration_ms: elapsed
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # Error classification
  # ---------------------------------------------------------------------------

  @doc """
  True when the error reason should be retried within the same tick.
  """
  @spec transient?(term()) :: boolean()
  def transient?(nil), do: false
  def transient?({:drive_error, code, _}) when code in [429, 500, 502, 503, 504], do: true
  def transient?({:drive_error, code, _}) when code in [400, 401, 403, 404], do: false
  def transient?({:drive_error, _, _}), do: false
  def transient?({:md5_mismatch, _, _}), do: false
  def transient?({:orphan_md5_mismatch, _}), do: false
  def transient?({:ambiguous_orphan, _}), do: false
  def transient?({:local_zip_missing, _}), do: false
  def transient?({:local_zip_read, _, _}), do: false
  def transient?(:disabled), do: false
  # `Uploader.build_conn_from_db/0` returns `{:error, {:disabled, _}}`
  # and `{:error, {:auth, _}}` — both permanent from the runner's POV:
  # credentials need to be re-uploaded / service-account needs fixing
  # before a retry could succeed.
  def transient?({:disabled, _}), do: false
  def transient?({:auth, _}), do: false
  # Unknown transport hiccup — safe to retry.
  def transient?({:transport, _}), do: true
  # Unknown error shape. Default to non-transient so a newly introduced
  # error doesn't silently turn into 3× retries; if a future reason is
  # genuinely retryable, add an explicit clause above.
  def transient?(_), do: false

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp classify_drive_error(%Tesla.Env{status: status, body: body}) do
    {:drive_error, status, extract_message(body)}
  end

  defp classify_drive_error({:ok, %Tesla.Env{status: status, body: body}}) do
    {:drive_error, status, extract_message(body)}
  end

  defp classify_drive_error({:error, reason}), do: {:transport, reason}
  defp classify_drive_error(other), do: {:transport, other}

  defp extract_message(%{"error" => %{"message" => msg}}), do: to_string(msg)
  defp extract_message(%{"error_description" => msg}), do: to_string(msg)
  defp extract_message(body) when is_binary(body), do: body
  defp extract_message(other), do: inspect(other)

  # Streaming md5 — 1 MiB chunks folded through :crypto.hash_*.
  defp file_md5(path) do
    try do
      hash =
        path
        |> Elixir.File.stream!([], @md5_chunk)
        |> Enum.reduce(:crypto.hash_init(:md5), fn chunk, acc ->
          :crypto.hash_update(acc, chunk)
        end)
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, hash}
    rescue
      e in Elixir.File.Error ->
        case e.reason do
          :enoent -> {:error, {:local_zip_missing, path}}
          other -> {:error, {:local_zip_read, path, other}}
        end
    end
  end

  defp size_to_int(nil), do: 0
  defp size_to_int(n) when is_integer(n), do: n

  defp size_to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> 0
    end
  end
end
