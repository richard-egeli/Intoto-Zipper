defmodule SynologyZipper.Uploader do
  @moduledoc """
  GenServer that serves `upload/2` requests serially — the BEAM
  serialises access so two concurrent runs don't pound the Drive API
  in parallel.

  State is one of:

    * `:dynamic` — production mode. Per upload, read the stored
      service-account JSON from the DB (see
      `SynologyZipper.State.get_drive_credentials/0`), fetch a fresh
      OAuth access token via `Goth.Token.fetch/1`, build a one-shot
      `Tesla.Client`, hand it to `Drive.upload/2`. If no credentials
      are configured, every call returns `{:error, {:disabled, …}}`
      and the UI shows a banner.
    * `{:static_conn, conn}` — test mode with an injected
      `Tesla.Client` (typically wired up against `Tesla.Mock`). Skips
      the credential / token plumbing entirely.

  Credentials are managed at runtime through the `/settings` page in
  the web UI — no files, no env vars, no bind-mounts.

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
    # `:infinity` for the same reason `upload/3` uses it: every public
    # call serialises through this one mailbox, so a probe fired from a
    # queued upload task would otherwise exit at the default 5s while
    # an earlier upload is still in-flight.
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
    state =
      case Keyword.get(opts, :conn) do
        nil -> :dynamic
        conn -> {:static_conn, conn}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:upload, job}, _from, {:static_conn, conn} = state) do
    {:reply, Drive.upload(conn, job), state}
  end

  def handle_call({:upload, job}, _from, :dynamic = state) do
    case build_conn_from_db() do
      {:ok, conn} ->
        {:reply, Drive.upload(conn, job), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:disabled?, _from, {:static_conn, _} = state) do
    {:reply, false, state}
  end

  def handle_call(:disabled?, _from, :dynamic = state) do
    {:reply, State.get_drive_credentials() == nil, state}
  end

  def handle_call(:disabled_reason, _from, {:static_conn, _} = state) do
    {:reply, nil, state}
  end

  def handle_call(:disabled_reason, _from, :dynamic = state) do
    reason =
      case State.get_drive_credentials() do
        nil -> "No Google Drive credentials have been uploaded yet."
        _ -> nil
      end

    {:reply, reason, state}
  end

  # ---------------------------------------------------------------------------
  # Credentials → Tesla.Client
  # ---------------------------------------------------------------------------

  defp build_conn_from_db do
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
