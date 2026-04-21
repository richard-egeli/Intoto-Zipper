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

  defp do_upload(conn, %Job{zip_path: path, drive_folder_id: folder_id}, name) do
    case file_md5(path) do
      {:ok, local_md5} ->
        start = System.monotonic_time(:millisecond)

        meta = %File{
          name: name,
          mimeType: "application/zip",
          parents: [folder_id]
        }

        # `drive_files_create_simple` takes a path string and Tesla's
        # multipart engine streams the file part from disk in chunks,
        # so peak memory stays flat regardless of zip size.
        case Files.drive_files_create_simple(
               conn,
               "multipart",
               meta,
               path,
               fields: "id,md5Checksum,size",
               supportsAllDrives: true
             ) do
          {:ok, %File{} = created} ->
            elapsed = System.monotonic_time(:millisecond) - start
            verify_and_finalise(conn, created, local_md5, elapsed)

          {:error, err} ->
            {:error, classify_drive_error(err)}
        end

      {:error, _} = err ->
        err
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
  def transient?(:disabled), do: false
  # Unknown transport hiccup — safe to retry.
  def transient?({:transport, _}), do: true
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
