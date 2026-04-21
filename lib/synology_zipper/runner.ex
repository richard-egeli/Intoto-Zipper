defmodule SynologyZipper.Runner do
  @moduledoc """
  Orchestrates one scheduler tick: plan → zip for every configured
  source, then run the upload phase. Source directories are always
  kept intact after zipping — the move-on-success behaviour was
  dropped with the UI that configured it.

  Behaviour:

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
          notes: String.t()
        }

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

    initial = %{run_id: run.id, months_zipped: 0, months_failed: 0, exit_status: "", notes: ""}

    result =
      State.list_sources()
      |> Enum.reduce(initial, fn source, acc ->
        process_source(source, Keyword.merge(opts, uploader: uploader), now, acc)
      end)

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

  defp process_month(source, month, _opts, acc) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, _} = State.start_month_attempt(source.name, month, now)

    case Zipper.write_zip(source.path, month) do
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

        %{acc | months_zipped: acc.months_zipped + 1}
    end
  end

  # ---------------------------------------------------------------------------
  # Upload phase
  # ---------------------------------------------------------------------------

  defp run_upload_phase(acc, uploader) do
    case State.months_pending_upload() do
      [] ->
        acc

      candidates ->
        Logger.info("upload phase start", candidates: length(candidates))

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
