defmodule SynologyZipper.IntegrationTest do
  @moduledoc """
  End-to-end smoke test for the full supervision tree. Boots the
  Scheduler + a stub uploader, creates one source backed by a real
  `tmp/` directory containing a `YYYY-MM-DD/` sub-folder, calls
  `Scheduler.run_now/0` and asserts that the month row flips to
  `status="zipped"` — verified both via `Phoenix.PubSub` subscription
  and a direct DB read.

  This exercises:
    * Application-tree registration of Scheduler / Uploader (the
      background workers are disabled by default in test env; this
      test boots its own supervised instances explicitly — the
      registration shape itself is smoke-tested by the same
      `SynologyZipper.Scheduler.start_link/1` being exercised here).
    * Runtime config overrides via application env (stub uploader
      injected through Scheduler `:run_opts`).
    * The full Runner → State → PubSub flow that the LiveViews
      depend on.
  """

  use SynologyZipper.DataCase, async: false

  alias SynologyZipper.{Scheduler, State, StubUploader}

  setup do
    # Elevate the sandbox to shared mode with the *test process* itself
    # as owner. The default `shared: true` in DataCase keeps the owner
    # as a separate Agent, which isn't enough for processes spawned
    # deep inside the Scheduler (which uses `spawn/1`, not
    # `spawn_link`). Making the test pid the shared owner means those
    # deep processes can see the sandbox regardless of lineage.
    Ecto.Adapters.SQL.Sandbox.mode(SynologyZipper.Repo, {:shared, self()})
    :ok
  end

  test "full supervision tree zips one month end-to-end and broadcasts via PubSub" do
    # 1. Fake source on disk.
    tmp = Path.join(System.tmp_dir!(), "synz_integ_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([tmp, "2025-01-15"]))
    File.write!(Path.join([tmp, "2025-01-15", "dummy.mp4"]), "hello world")
    on_exit(fn -> File.rm_rf!(tmp) end)

    # 2. Configure the source in the DB. The State context broadcasts
    # {:source_changed, _} on the "sources" topic.
    {:ok, _source} =
      State.upsert_source(%{
        name: "integ",
        path: tmp,
        start_month: "2025-01",
        grace_days: 3,
        auto_upload: false
      })

    # Subscribe to the source's per-source topic and the runs topic so
    # we catch {:month_changed, _, _} + {:run_end, _, _}.
    :ok = State.subscribe_source("integ")
    :ok = Phoenix.PubSub.subscribe(SynologyZipper.PubSub, "runs")

    # 3. Boot a stub uploader. The run is auto_upload=false, so the
    # uploader is never invoked; we include it purely to exercise
    # the Runner's uploader-handle seam.
    stub_name = :"integ_stub_#{System.unique_integer([:positive])}"
    {:ok, stub_pid} = StubUploader.start_link(name: stub_name, disabled: true)
    on_exit(fn -> if Process.alive?(stub_pid), do: Process.exit(stub_pid, :normal) end)

    # 4. Boot a Scheduler with a large tick interval — only run_now/1
    # triggers work during the test. The `:run_opts` are plumbed
    # through to `Runner.run/1` exactly as they would be in
    # production runtime config.
    sched_name = :"integ_sched_#{System.unique_integer([:positive])}"

    {:ok, sched_pid} =
      Scheduler.start_link(
        name: sched_name,
        tick_interval_ms: 3_600_000,
        initial_delay_ms: 0,
        run_opts: [
          uploader: {StubUploader, stub_name},
          now: ~U[2025-04-01 00:00:00Z]
        ]
      )

    on_exit(fn -> if Process.alive?(sched_pid), do: GenServer.stop(sched_pid) end)

    # 5. Trigger a run.
    :ok = Scheduler.run_now(sched_name)

    # 6. Wait for the run to fully complete. The Runner broadcasts
    # {:month_changed, _, _} twice per month (once on
    # start_month_attempt, once on mark_zipped), so we can't just
    # read after the first broadcast — wait for the Scheduler's
    # terminal {:run_end, _, _} instead.
    assert_receive {:month_changed, "integ", "2025-01"}, 5_000
    assert_receive {:run_end, _id, status}, 5_000
    assert status in ["ok", "partial"]

    # 7. Final DB state.
    month = State.get_month("integ", "2025-01")
    assert month.status == "zipped", "month.error was: #{inspect(month.error)}"
    assert month.file_count == 1
    assert month.zip_bytes > 0

    # 8. Zip artefact written atomically next to the source folder.
    assert File.exists?(Path.join(tmp, "2025-01.zip"))

    # 9. Scheduler + stub are both alive (wiring smoke-test).
    assert Process.alive?(sched_pid)
    assert Process.alive?(stub_pid)
  end
end
