defmodule SynologyZipper.Runner do
  @moduledoc """
  Orchestrates one scheduler tick: plan → zip for every configured
  source, then run the upload phase. Source directories are always
  kept intact after zipping — the move-on-success behaviour was
  dropped with the UI that configured it.

  Behaviour:

    * Zip and upload run concurrently: as soon as a month finishes
      zipping, an async Task is fired to upload it. The zip phase
      keeps moving to the next month immediately; at end of the zip
      phase we await any outstanding upload tasks. The Uploader
      GenServer still serialises actual Drive traffic so this
      doesn't fan out API calls — it only overlaps disk-I/O with
      network-I/O, which are disjoint bottlenecks.
    * Upload failures do NOT bump the run's `months_failed` counter;
      they are recorded per-month in `upload_error` / `upload_attempts`.
    * On process death mid-zip, the month row is already in
      `status=failed` + `attempt_count` incremented, so the next tick
      retries cleanly without double-counting a partial zip.
  """

  require Logger

  alias SynologyZipper.{Planner, Retry, State, Zipper}
  alias SynologyZipper.Uploader
  alias SynologyZipper.Uploader.{Drive, Job}

  @type result :: %{
          run_id: integer(),
          months_zipped: non_neg_integer(),
          months_failed: non_neg_integer(),
          exit_status: String.t(),
          notes: String.t(),
          upload_tasks: [Task.t()]
        }

  # Per-task upload timeout. Long because uploads are serialised
  # through the Uploader GenServer — N queued tasks share the same
  # Drive API pipe. 4h is way more than any realistic real-world zip
  # should take, and we'd rather await-then-log than force-kill a
  # legitimate in-flight upload.
  @upload_await_timeout_ms :timer.hours(4)

  @doc """
  Entrypoint used by the scheduler and by integration tests.

  Options:
    * `:now` — `DateTime` (defaults to `DateTime.utc_now/0`). The
      "today" handed to the planner.
    * `:uploader` — module implementing `upload/2` +
      `disabled?/0` + `disabled_reason/0` (defaults to
      `SynologyZipper.Uploader`). Tests inject a stub.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    now = now(opts)
    uploader = Keyword.get(opts, :uploader, Uploader)

    run = State.start_run(now)
    Logger.info("run start", run_id: run.id)
    Phoenix.PubSub.broadcast(SynologyZipper.PubSub, "runs", {:run_start, run.id})

    initial = %{
      run_id: run.id,
      months_zipped: 0,
      months_failed: 0,
      exit_status: "",
      notes: "",
      upload_tasks: [],
      # `{source_name, month}` tuples we already fired async uploads
      # for in this tick. The safety-net upload phase filters these
      # out so we don't attempt a second upload on the same row and
      # double-count `upload_attempts`.
      attempted: MapSet.new()
    }

    # Zip phase. Each successful non-empty zip fires an async upload
    # task that piles into `acc.upload_tasks`.
    result =
      State.list_sources()
      |> Enum.reduce(initial, fn source, acc ->
        process_source(source, Keyword.merge(opts, uploader: uploader), now, acc)
      end)

    # Wait for the uploads we started during the zip phase. They
    # were collected in reverse-zipped order; reverse for log order.
    await_uploads(Enum.reverse(result.upload_tasks))
    result = %{result | upload_tasks: []}

    # Safety net: picks up any zipped-but-not-yet-uploaded months
    # from a *prior* tick that was interrupted. Skips months already
    # attempted by the async phase in this tick. In steady state this
    # finds zero candidates.
    result = run_upload_phase(result, uploader)

    exit_status =
      cond do
        result.months_failed > 0 -> "partial"
        result.exit_status == "" -> "ok"
        true -> result.exit_status
      end

    result = %{result | exit_status: exit_status}

    State.finish_run(
      run.id,
      DateTime.utc_now() |> DateTime.truncate(:second),
      result.exit_status,
      result.months_zipped,
      result.months_failed,
      result.notes
    )

    Logger.info("run end",
      run_id: run.id,
      exit_status: result.exit_status,
      months_zipped: result.months_zipped,
      months_failed: result.months_failed
    )

    result
  end

  # ---------------------------------------------------------------------------
  # Per-source plan + zip
  # ---------------------------------------------------------------------------

  defp process_source(source, opts, now, acc) do
    today = DateTime.to_date(now)
    zipped = State.zipped_months(source.name)

    candidates =
      Planner.candidate_months(source.start_month, today, source.grace_days, zipped)

    Logger.info("source plan", source: source.name, candidates: length(candidates))

    Enum.reduce(candidates, acc, fn month, inner_acc ->
      process_month(source, month, opts, inner_acc)
    end)
  end

  defp process_month(source, month, opts, acc) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, _} = State.start_month_attempt(source.name, month, now)

    watcher = start_progress_watcher(source.name, source.path, month)

    try_result =
      try do
        Zipper.write_zip(source.path, month)
      after
        stop_progress_watcher(watcher)
      end

    case try_result do
      {:error, reason} ->
        Logger.error("zip failed",
          source: source.name,
          month: month,
          error: inspect(reason)
        )

        _ = State.mark_failed(source.name, month, DateTime.utc_now() |> DateTime.truncate(:second), inspect(reason))
        %{acc | months_failed: acc.months_failed + 1}

      {:ok, %{file_count: 0}} ->
        {:ok, _} = State.mark_zipped_empty(source.name, month, DateTime.utc_now() |> DateTime.truncate(:second))
        Logger.warning("empty month zipped", source: source.name, month: month)
        %{acc | months_zipped: acc.months_zipped + 1}

      {:ok, %{path: path, bytes: bytes, file_count: fc, skipped: skipped}} ->
        {:ok, _} =
          State.mark_zipped(source.name, month, DateTime.utc_now() |> DateTime.truncate(:second), path, bytes, fc)

        Logger.info("zipped",
          source: source.name,
          month: month,
          file_count: fc,
          bytes: bytes,
          skipped: skipped
        )

        acc
        |> Map.update!(:months_zipped, &(&1 + 1))
        |> maybe_queue_upload(source, month, path, opts)
    end
  end

  # Fires an async upload task when the source has auto-upload on and
  # a Drive folder id set. The task body wraps upload_one/2 so a
  # single task failure never crashes the Runner reducer; mark_* is
  # called from inside the task for state updates.
  defp maybe_queue_upload(
         acc,
         %{auto_upload: true, drive_folder_id: folder_id} = source,
         month,
         zip_path,
         opts
       )
       when is_binary(folder_id) and folder_id != "" and is_binary(zip_path) do
    uploader = Keyword.fetch!(opts, :uploader)

    candidate = %{
      source_name: source.name,
      month: month,
      zip_path: zip_path,
      drive_folder_id: folder_id
    }

    task = Task.async(fn -> run_async_upload(candidate, uploader) end)

    %{
      acc
      | upload_tasks: [task | acc.upload_tasks],
        attempted: MapSet.put(acc.attempted, {source.name, month})
    }
  end

  defp maybe_queue_upload(acc, _source, _month, _zip_path, _opts), do: acc

  # Body of an async upload task. Mirrors the synchronous upload_one
  # path and also handles the "uploader disabled" case so we mark the
  # month's upload_error immediately instead of silently skipping.
  defp run_async_upload(candidate, uploader) do
    if uploader_disabled?(uploader) do
      _ = State.mark_upload_failed(candidate.source_name, candidate.month, disabled_reason(uploader))
      :disabled
    else
      upload_one(candidate, uploader)
      :ok
    end
  rescue
    e ->
      Logger.error("async upload task crashed",
        source: candidate.source_name,
        month: candidate.month,
        error: inspect(e)
      )

      _ =
        State.mark_upload_failed(
          candidate.source_name,
          candidate.month,
          "async upload crashed: #{inspect(e)}"
        )

      :crashed
  end

  defp await_uploads([]), do: :ok

  defp await_uploads(tasks) do
    Logger.info("awaiting in-flight uploads", count: length(tasks))

    Enum.each(tasks, fn task ->
      try do
        Task.await(task, @upload_await_timeout_ms)
      catch
        :exit, reason ->
          Logger.error("async upload task exited abnormally", reason: inspect(reason))
          # Task.await(4h) timeout or task crash → make sure the task
          # is stopped so it doesn't linger after the run ends.
          _ = Task.shutdown(task, :brutal_kill)
      end
    end)

    Logger.info("in-flight uploads drained")
  end

  # ---------------------------------------------------------------------------
  # Per-month progress watcher
  # ---------------------------------------------------------------------------
  #
  # `:zip.create/3` is a single blocking call with no per-file callback,
  # so we can't report progress from inside it. Instead we spawn a tiny
  # watcher that polls the `.<month>.zip.tmp` file's size every 2s and
  # broadcasts `{:zip_progress, source_name, month, bytes_so_far}` on
  # the per-source topic. The LiveView handles it and updates the row.
  # Stops on `:stop` or when its parent dies.

  @progress_poll_interval_ms 2_000

  defp start_progress_watcher(source_name, source_path, month) do
    tmp = Path.join(source_path, ".#{month}.zip.tmp")
    topic = State.source_topic(source_name)
    pubsub = SynologyZipper.PubSub

    spawn(fn -> progress_loop(tmp, source_name, month, topic, pubsub) end)
  end

  defp progress_loop(tmp, source_name, month, topic, pubsub) do
    receive do
      :stop -> :ok
    after
      @progress_poll_interval_ms ->
        case Elixir.File.stat(tmp) do
          {:ok, %Elixir.File.Stat{size: size}} when size > 0 ->
            Phoenix.PubSub.broadcast(
              pubsub,
              topic,
              {:zip_progress, source_name, month, size}
            )

          _ ->
            :ok
        end

        progress_loop(tmp, source_name, month, topic, pubsub)
    end
  end

  defp stop_progress_watcher(pid) when is_pid(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
    :ok
  end

  defp stop_progress_watcher(_), do: :ok

  # ---------------------------------------------------------------------------
  # Upload phase
  # ---------------------------------------------------------------------------

  defp run_upload_phase(acc, uploader) do
    # Skip anything the async phase already handled this tick.
    candidates =
      State.months_pending_upload()
      |> Enum.reject(fn c -> MapSet.member?(acc.attempted, {c.source_name, c.month}) end)

    case candidates do
      [] ->
        acc

      _ ->
        Logger.info("upload phase start (prior-tick carryover)", candidates: length(candidates))

        cond do
          uploader_disabled?(uploader) ->
            mark_all_disabled(candidates, uploader)
            acc

          true ->
            Enum.reduce(candidates, acc, fn cand, acc ->
              upload_one(cand, uploader)
              acc
            end)
            |> tap(fn _ -> Logger.info("upload phase end") end)
        end
    end
  end

  defp uploader_disabled?(Uploader), do: Uploader.disabled?()
  defp uploader_disabled?(mod) when is_atom(mod), do: apply(mod, :disabled?, [])
  defp uploader_disabled?({mod, name}), do: apply(mod, :disabled?, [name])
  defp uploader_disabled?(_), do: false

  defp disabled_reason(Uploader), do: Uploader.disabled_reason() || "drive uploader disabled"

  defp disabled_reason(mod) when is_atom(mod),
    do: apply(mod, :disabled_reason, []) || "drive uploader disabled"

  defp disabled_reason({mod, name}),
    do: apply(mod, :disabled_reason, [name]) || "drive uploader disabled"

  defp disabled_reason(_), do: "drive uploader disabled"

  defp mark_all_disabled(candidates, uploader) do
    reason = disabled_reason(uploader)
    Logger.warning("uploader disabled — marking candidates", reason: reason)

    Enum.each(candidates, fn c ->
      _ = State.mark_upload_failed(c.source_name, c.month, reason)
    end)
  end

  defp upload_one(candidate, uploader) do
    job = %Job{
      source_name: candidate.source_name,
      month: candidate.month,
      zip_path: candidate.zip_path,
      drive_folder_id: candidate.drive_folder_id
    }

    result =
      Retry.run(
        fn -> do_upload(uploader, job) end,
        %{attempts: 3, base: 2_000},
        &Drive.transient?/1
      )

    case result do
      {:ok, %{drive_file_id: file_id}} ->
        _ = State.mark_uploaded(candidate.source_name, candidate.month, file_id, DateTime.utc_now() |> DateTime.truncate(:second))

        Logger.info("uploaded",
          source: candidate.source_name,
          month: candidate.month,
          file_id: file_id
        )

      {:error, reason} ->
        Logger.error("upload failed",
          source: candidate.source_name,
          month: candidate.month,
          error: inspect(reason)
        )

        _ =
          State.mark_upload_failed(
            candidate.source_name,
            candidate.month,
            reason_string(reason)
          )
    end
  end

  # Tolerate both {:ok, _}/{:error, _} and bare :ok from Retry.run.
  defp do_upload(Uploader, job), do: Uploader.upload(job)
  defp do_upload(mod, job) when is_atom(mod), do: apply(mod, :upload, [job])
  defp do_upload({mod, name}, job), do: apply(mod, :upload, [name, job])

  defp reason_string(r) when is_binary(r), do: r
  defp reason_string(r), do: inspect(r)

  # Ecto's :utc_datetime type rejects microseconds. DateTime.utc_now/0
  # returns usec precision, so every datetime that reaches the DB must
  # be truncated to seconds.
  defp now(opts) do
    case Keyword.get(opts, :now) do
      nil ->
        DateTime.utc_now() |> DateTime.truncate(:second)

      %DateTime{microsecond: {0, _}} = d ->
        d

      %DateTime{} = d ->
        DateTime.truncate(d, :second)
    end
  end
end
