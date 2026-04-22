defmodule SynologyZipper.Uploader do
  @moduledoc """
  Single-worker upload gateway. Serialises calls to
  `SynologyZipper.Uploader.Drive.upload/2` so two concurrent runs can't
  pound the Drive API in parallel, but does NOT block its own mailbox
  for the duration of each upload.

  Shape:

    * `handle_call({:upload, job}, from, state)` — if idle, resolves a
      `Tesla.Client` (from the injected `:conn` in test mode or from
      the DB credentials in `:dynamic` mode) and spawns a Task under
      `SynologyZipper.UploadTaskSupervisor` to do the actual Drive I/O.
      If busy, the `{from, job}` pair is appended to an in-state FIFO
      queue. Returns `{:noreply, state}` in both cases — the reply is
      delivered via `GenServer.reply/2` when the Task finishes.
    * `handle_call(:disabled?, _, state)` /
      `handle_call(:disabled_reason, _, state)` — always reply in-line
      regardless of whether an upload is in flight. Pre-rework these
      queued behind the active `:upload` call and exited at the default
      5s; now the GenServer is free to serve probes immediately.
    * `handle_info({ref, result}, state)` — Task finished; reply to the
      caller that owns `ref`, then dequeue the next pending job.
    * `handle_info({:DOWN, ref, :process, _pid, reason}, state)` — Task
      died without sending a result (supervisor brutal-kill, VM kill,
      etc.). Reply with `{:error, {:upload_crashed, reason}}`, dequeue.

  State is:

      %{
        mode: :dynamic | {:static_conn, Tesla.Env.client()},
        busy: %{from: GenServer.from(), task_ref: reference(), task_pid: pid()} | nil,
        queue: :queue.queue({GenServer.from(), Job.t()})
      }

  *This module does not retry.* The runner wraps each call in
  `SynologyZipper.Retry.run/3` using `Drive.transient?/1`.
  """

  use GenServer

  require Logger

  alias SynologyZipper.State
  alias SynologyZipper.Uploader.{Drive, Job}

  @name __MODULE__
  # `:infinity` because every public call serialises through this one
  # mailbox and the real transport bound lives in the Tesla/Finch
  # adapter (see `config/config.exs` — `receive_timeout: 30 min`).
  # Large month zips on a residential uplink take hours; a caller-side
  # timeout here would just strand the still-running upload while
  # killing the async Task.
  @default_timeout :infinity
  @scopes ["https://www.googleapis.com/auth/drive.file"]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Perform one upload. Serialised through the GenServer so two
  concurrent runs don't pound the Drive API in parallel.

  Return shape mirrors `Drive.upload/2`.
  """
  @spec upload(GenServer.server(), Job.t(), timeout()) ::
          {:ok, SynologyZipper.Uploader.Result.t()} | {:error, term()}
  def upload(server \\ @name, %Job{} = job, timeout \\ @default_timeout) do
    GenServer.call(server, {:upload, job}, timeout)
  end

  @doc "True when no Drive credentials are currently configured."
  @spec disabled?(GenServer.server()) :: boolean()
  def disabled?(server \\ @name) do
    GenServer.call(server, :disabled?, @default_timeout)
  end

  @doc """
  Human-readable reason when `disabled?/0` is true, else `nil`.
  Rendered in the credentials-missing banner.
  """
  @spec disabled_reason(GenServer.server()) :: String.t() | nil
  def disabled_reason(server \\ @name) do
    GenServer.call(server, :disabled_reason, @default_timeout)
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    mode =
      case Keyword.get(opts, :conn) do
        nil -> :dynamic
        conn -> {:static_conn, conn}
      end

    # `Task.Supervisor.async_nolink/2` propagates the current process's
    # `$callers` into the spawned Task's dictionary — but GenServer
    # start_link doesn't set `$callers` in the first place (it's a
    # Task-family convention). Seed it from `$ancestors`, which
    # `:proc_lib` does set, so tools that walk the caller chain
    # (`Tesla.Mock`, Ecto sandbox, telemetry) can trace through from
    # our uploads back to whoever spawned us. No-op in prod (the
    # uploader's ancestors are just the Application supervisor).
    Process.put(:"$callers", Process.get(:"$ancestors", []))

    {:ok, %{mode: mode, busy: nil, queue: :queue.new()}}
  end

  @impl true
  def handle_call({:upload, job}, from, %{busy: nil} = state) do
    {:noreply, dispatch(job, from, state)}
  end

  def handle_call({:upload, job}, from, %{busy: %{}} = state) do
    {:noreply, %{state | queue: :queue.in({from, job}, state.queue)}}
  end

  def handle_call(:disabled?, _from, %{mode: {:static_conn, _}} = state) do
    {:reply, false, state}
  end

  def handle_call(:disabled?, _from, %{mode: :dynamic} = state) do
    {:reply, State.get_drive_credentials() == nil, state}
  end

  def handle_call(:disabled_reason, _from, %{mode: {:static_conn, _}} = state) do
    {:reply, nil, state}
  end

  def handle_call(:disabled_reason, _from, %{mode: :dynamic} = state) do
    reason =
      case State.get_drive_credentials() do
        nil -> "No Google Drive credentials have been uploaded yet."
        _ -> nil
      end

    {:reply, reason, state}
  end

  # Task finished normally — `{ref, result}` is the standard Task reply
  # shape. `Process.demonitor(ref, [:flush])` drops the pending :DOWN.
  @impl true
  def handle_info({ref, result}, %{busy: %{task_ref: ref, from: from}} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, result)
    {:noreply, dequeue_next(state)}
  end

  # Task died without sending a result (e.g. supervisor brutal-kill).
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{busy: %{task_ref: ref, from: from}} = state
      ) do
    Logger.error("upload task crashed without replying", reason: inspect(reason))
    GenServer.reply(from, {:error, {:upload_crashed, reason}})
    {:noreply, dequeue_next(state)}
  end

  # Stale :DOWN from a demonitored-but-not-yet-flushed task, or any
  # unrelated message. Ignore.
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Resolve a connection (fast — static handoff or one DB+Goth call),
  # then spawn an unlinked-but-monitored Task to do the actual Drive
  # I/O. Keeping the `build_conn_from_db/0` step in this process keeps
  # the SQL-sandbox grant intact in tests (the Task would otherwise
  # need its own `Sandbox.allow` call, which we can't issue ahead of
  # time for a not-yet-spawned pid).
  defp dispatch(job, from, %{mode: mode} = state) do
    conn_result = build_conn(mode)

    task =
      Task.Supervisor.async_nolink(
        SynologyZipper.UploadTaskSupervisor,
        fn ->
          case conn_result do
            {:ok, conn} -> Drive.upload(conn, job)
            {:error, _} = err -> err
          end
        end
      )

    %{state | busy: %{from: from, task_ref: task.ref, task_pid: task.pid}}
  end

  defp dequeue_next(%{queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, {from, job}}, queue2} ->
        dispatch(job, from, %{state | busy: nil, queue: queue2})

      {:empty, _} ->
        %{state | busy: nil}
    end
  end

  defp build_conn({:static_conn, conn}), do: {:ok, conn}

  defp build_conn(:dynamic) do
    case State.get_drive_credentials() do
      nil ->
        {:error, {:disabled, "no credentials"}}

      creds ->
        case Goth.Token.fetch(source: {:service_account, creds, scopes: @scopes}) do
          {:ok, %{token: token}} ->
            {:ok, GoogleApi.Drive.V3.Connection.new(token)}

          {:error, reason} ->
            {:error, {:auth, reason}}
        end
    end
  end
end
