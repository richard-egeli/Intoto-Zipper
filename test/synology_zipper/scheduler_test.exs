defmodule SynologyZipper.SchedulerTest do
  use ExUnit.Case, async: false

  alias SynologyZipper.Scheduler

  # A tiny in-line runner that publishes the same shape the real one
  # does, plus a blocker so we can observe `running?/0` mid-flight.
  # Uses a named ETS table as a rendezvous instead of sending messages
  # blindly (which breaks when a Registry process is lurking).
  defmodule SlowRunner do
    @gate :slow_runner_gate

    def prepare do
      if :ets.whereis(@gate) == :undefined do
        :ets.new(@gate, [:named_table, :public, :set])
      end

      :ets.insert(@gate, {:released, false})
    end

    def release, do: :ets.insert(@gate, {:released, true})

    def run(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      id = Keyword.fetch!(opts, :id)
      Phoenix.PubSub.broadcast(SynologyZipper.PubSub, "runs", {:run_start, id})
      send(test_pid, {:run_started, id})

      wait_for_release()

      %{
        run_id: id,
        months_zipped: 0,
        months_failed: 0,
        exit_status: "ok",
        notes: ""
      }
    end

    defp wait_for_release do
      case :ets.lookup(@gate, :released) do
        [{:released, true}] -> :ok
        _ ->
          Process.sleep(10)
          wait_for_release()
      end
    end
  end

  defmodule FastRunner do
    def run(_opts) do
      id = System.unique_integer([:positive])
      Phoenix.PubSub.broadcast(SynologyZipper.PubSub, "runs", {:run_start, id})

      %{
        run_id: id,
        months_zipped: 0,
        months_failed: 0,
        exit_status: "ok",
        notes: ""
      }
    end
  end

  defmodule CrashyRunner do
    def run(_opts), do: raise("boom")
  end

  defp start_scheduler!(opts) do
    name = :"scheduler_#{System.unique_integer([:positive])}"

    # 0 initial_delay with a huge tick interval means we only run on
    # explicit run_now/1.
    opts =
      Keyword.merge(
        [
          name: name,
          tick_interval_ms: 3_600_000,
          initial_delay_ms: 0,
          # The sandbox owner can't hand an ownership grant to a
          # process that doesn't exist yet; the boot sweep lives in
          # `init/1`, which runs before `start_link` returns. Opt out
          # here; `clear_stale_upload_starts/0` has its own unit test.
          sweep_on_init: false
        ],
        opts
      )

    {:ok, pid} = Scheduler.start_link(opts)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    name
  end

  setup do
    :ok = Phoenix.PubSub.subscribe(SynologyZipper.PubSub, "runs")
    :ok
  end

  test "run_now triggers a run and broadcasts :run_start / :run_end" do
    name =
      start_scheduler!(
        runner: FastRunner,
        run_opts: [],
        initial_delay_ms: 0
      )

    :ok = Scheduler.run_now(name)

    assert_receive {:run_start, _id}, 1_000
    assert_receive {:run_end, _id, "ok"}, 1_000
  end

  test "running?/0 is true while the runner is in flight and false after" do
    SlowRunner.prepare()
    test_pid = self()
    id = 999

    name =
      start_scheduler!(
        runner: SlowRunner,
        run_opts: [test_pid: test_pid, id: id],
        initial_delay_ms: 0
      )

    :ok = Scheduler.run_now(name)
    assert_receive {:run_started, ^id}, 1_000
    assert Scheduler.running?(name)

    SlowRunner.release()

    assert_receive {:run_end, _id, "ok"}, 1_000
    refute Scheduler.running?(name)
  end

  test "run_now while running enqueues a second run; subsequent ones are skipped" do
    SlowRunner.prepare()
    test_pid = self()
    id = 1001

    name =
      start_scheduler!(
        runner: SlowRunner,
        run_opts: [test_pid: test_pid, id: id],
        initial_delay_ms: 0
      )

    :ok = Scheduler.run_now(name)
    assert_receive {:run_started, ^id}, 1_000

    assert :ok = Scheduler.run_now(name)
    assert {:skipped, :already_queued} = Scheduler.run_now(name)

    # Release — the first run observes `:released == true` and returns;
    # the queued second run re-reads the same gate and immediately
    # returns as well (no re-block needed — single-shot test).
    SlowRunner.release()

    assert_receive {:run_started, ^id}, 2_000
    assert_receive {:run_end, _id, "ok"}, 2_000
    assert_receive {:run_end, _id, "ok"}, 2_000
  end

  test "a runner crash surfaces as a :crashed run_end and the scheduler survives" do
    name = start_scheduler!(runner: CrashyRunner, run_opts: [], initial_delay_ms: 0)

    :ok = Scheduler.run_now(name)

    assert_receive {:run_end, _id, :crashed}, 1_000

    # Scheduler process still alive.
    refute Scheduler.running?(name)
    assert is_pid(Process.whereis(name))
  end
end
