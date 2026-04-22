defmodule SynologyZipper.Scheduler do
  @moduledoc """
  Fires `SynologyZipper.Runner.run/1` on a recurring tick and on
  external triggers. Ports `internal/scheduler/scheduler.go`:

    * A single run executes at a time; concurrent triggers are coalesced.
    * Each run is executed inside an async `Task` so a crash is
      contained (the scheduler process survives) and the supervisor
      restart policy does not cascade.
    * Broadcasts `{:run_start, run_id}` and
      `{:run_end, run_id, status}` on the `"runs"` PubSub topic so the
      LiveView status pill updates without polling.

  Configurable via application env:

      config :synology_zipper, SynologyZipper.Scheduler,
        tick_interval_ms: 60 * 60 * 1000,
        initial_delay_ms: 1_000

  `initial_delay_ms` must be a positive integer. Passing `0` (or anything
  the `> 0` guard in `schedule_next_tick/1` rejects) skips the initial
  tick — since recurring ticks are only re-armed from inside
  `handle_info(:tick, ...)`, that leaves the scheduler in a manual-only
  state. Tests use that on purpose; prod must not.
  """

  use GenServer

  require Logger

  alias SynologyZipper.{Runner, State}

  @pubsub SynologyZipper.PubSub
  @name __MODULE__

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Request an immediate run. Returns `:ok` (enqueued or started) or
  `{:skipped, :already_queued}` when one is already in flight AND another
  is already queued.
  """
  @spec run_now(GenServer.server()) :: :ok | {:skipped, atom()}
  def run_now(server \\ @name), do: GenServer.call(server, :run_now)

  @doc "True while a run is currently executing."
  @spec running?(GenServer.server()) :: boolean()
  def running?(server \\ @name), do: GenServer.call(server, :running?)

  @doc "The most recent `Runner.run/1` result or `nil`."
  @spec last_run(GenServer.server()) :: Runner.result() | nil
  def last_run(server \\ @name), do: GenServer.call(server, :last_run)

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    cfg = Application.get_env(:synology_zipper, __MODULE__, [])

    tick_interval_ms =
      Keyword.get(opts, :tick_interval_ms, Keyword.get(cfg, :tick_interval_ms, 60 * 60 * 1000))

    initial_delay_ms =
      Keyword.get(opts, :initial_delay_ms, Keyword.get(cfg, :initial_delay_ms, 0))

    runner = Keyword.get(opts, :runner, Runner)
    run_opts = Keyword.get(opts, :run_opts, [])

    # Boot sweep: if the BEAM died mid-upload, the month row still has
    # `upload_started_at` set. Nothing is actually in flight anymore,
    # so clear those flags. The safety-net upload phase will pick the
    # row up on the next tick; `Drive.upload` handles partial-upload
    # recovery via orphan adoption (list-before-create + md5 verify).
    # Opt-out for tests that start their own Scheduler without a Repo.
    if Keyword.get(opts, :sweep_on_init, true) do
      :ok = State.clear_stale_upload_starts()
    end

    state = %{
      tick_interval_ms: tick_interval_ms,
      runner: runner,
      run_opts: run_opts,
      running: false,
      queued: false,
      task: nil,
      last_run: nil,
      current_run_id: nil
    }

    schedule_next_tick(initial_delay_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    cond do
      state.running and state.queued ->
        {:reply, {:skipped, :already_queued}, state}

      state.running ->
        {:reply, :ok, %{state | queued: true}}

      true ->
        {:reply, :ok, start_run(state)}
    end
  end

  def handle_call(:running?, _from, state), do: {:reply, state.running, state}
  def handle_call(:last_run, _from, state), do: {:reply, state.last_run, state}

  @impl true
  def handle_info(:tick, state) do
    schedule_next_tick(state.tick_interval_ms)

    if state.running do
      Logger.info("skipping tick: run already in progress")
      {:noreply, state}
    else
      {:noreply, start_run(state)}
    end
  end

  # Runner finished (successfully or with a trapped crash marker).
  def handle_info(
        {:runner_result, pid, result},
        %{task: %{pid: pid, ref: ref}} = state
      ) do
    Process.demonitor(ref, [:flush])

    case result do
      {:__runner_crashed__, reason, _st} ->
        Logger.error("scheduler run crashed", reason: inspect(reason))
        broadcast({:run_end, state.current_run_id, :crashed})
        after_run(state)

      %{} = res ->
        broadcast({:run_end, res.run_id, res.exit_status})
        after_run(%{state | last_run: res})
    end
  end

  # Process died without sending :runner_result (e.g. kill signal).
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task: %{ref: ref}} = state
      ) do
    if reason != :normal do
      Logger.error("scheduler run crashed", reason: inspect(reason))
      broadcast({:run_end, state.current_run_id, :crashed})
    end

    after_run(state)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp schedule_next_tick(interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :tick, interval)
    :ok
  end

  defp schedule_next_tick(_), do: :ok

  defp start_run(state) do
    parent = self()
    run_opts = state.run_opts
    runner = state.runner

    # Spawn the runner in an *unlinked* process that we monitor
    # ourselves. A crash inside the runner must not propagate to the
    # scheduler — we want to record :crashed and keep accepting ticks.
    pid =
      spawn(fn ->
        result =
          try do
            apply(runner, :run, [run_opts])
          rescue
            e -> {:__runner_crashed__, e, __STACKTRACE__}
          catch
            kind, reason -> {:__runner_crashed__, {kind, reason}, []}
          end

        send(parent, {:runner_result, self(), result})
      end)

    ref = Process.monitor(pid)
    task = %{pid: pid, ref: ref}

    %{state | running: true, task: task, current_run_id: nil}
  end

  defp after_run(state) do
    state = %{state | running: false, task: nil, current_run_id: nil}

    if state.queued do
      {:noreply, start_run(%{state | queued: false})}
    else
      {:noreply, state}
    end
  end

  defp broadcast(msg) do
    Phoenix.PubSub.broadcast(@pubsub, "runs", msg)
  end
end
