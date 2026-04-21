defmodule SynologyZipper.Uploader do
  @moduledoc """
  GenServer that owns the Drive credentials (service-account JSON +
  scopes) and serves `upload/2` requests serially.

  State is one of:

    * `{:ready, :auth, %{creds: creds, scopes: scopes}}` — credentials
      loaded; every `upload/2` fetches a fresh OAuth access token via
      `Goth.Token.fetch/1` and builds a one-shot `Tesla.Client`. Short
      per-upload round-trip to Google, but no stale-token failure mode.
    * `{:ready, :static_conn, conn}` — test mode with an injected
      `Tesla.Client` (typically wired up against `Tesla.Mock`).
    * `{:disabled, reason}` — no usable credentials; every `upload/2`
      returns `{:error, {:disabled, reason}}`. Logged once at startup
      so the UI can surface a banner.

  *This module does not retry.* The runner wraps each call in
  `SynologyZipper.Retry.run/3` using `Drive.transient?/1`.
  """

  use GenServer

  require Logger

  alias SynologyZipper.Uploader.{Drive, Job}

  @name __MODULE__
  @default_timeout :timer.minutes(15)
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

  @doc "True when there are no usable credentials."
  @spec disabled?(GenServer.server()) :: boolean()
  def disabled?(server \\ @name) do
    GenServer.call(server, :disabled?)
  end

  @doc """
  Human-readable reason when `disabled?/0` is true, else `nil`.
  Rendered in the credentials-missing banner.
  """
  @spec disabled_reason(GenServer.server()) :: String.t() | nil
  def disabled_reason(server \\ @name) do
    GenServer.call(server, :disabled_reason)
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    state =
      case Keyword.get(opts, :conn) do
        nil -> build_state(opts)
        conn -> {:ready, :static_conn, conn}
      end

    case state do
      {:ready, _, _} ->
        Logger.info("drive uploader ready")

      {:disabled, reason} ->
        Logger.warning("drive uploader disabled", reason: reason)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:upload, job}, _from, {:ready, :static_conn, conn} = state) do
    {:reply, Drive.upload(conn, job), state}
  end

  def handle_call({:upload, job}, _from, {:ready, :auth, %{creds: creds, scopes: scopes}} = state) do
    case Goth.Token.fetch(source: {:service_account, creds, scopes: scopes}) do
      {:ok, %{token: token}} ->
        conn = GoogleApi.Drive.V3.Connection.new(token)
        {:reply, Drive.upload(conn, job), state}

      {:error, reason} ->
        {:reply, {:error, {:auth, reason}}, state}
    end
  end

  def handle_call({:upload, _job}, _from, {:disabled, reason} = state) do
    {:reply, {:error, {:disabled, reason}}, state}
  end

  def handle_call(:disabled?, _from, {:disabled, _} = state), do: {:reply, true, state}
  def handle_call(:disabled?, _from, state), do: {:reply, false, state}

  def handle_call(:disabled_reason, _from, {:disabled, reason} = state),
    do: {:reply, reason, state}

  def handle_call(:disabled_reason, _from, state), do: {:reply, nil, state}

  # ---------------------------------------------------------------------------
  # Credentials wiring
  # ---------------------------------------------------------------------------

  defp build_state(opts) do
    credentials_path =
      Keyword.get(opts, :credentials_path) ||
        System.get_env("GOOGLE_APPLICATION_CREDENTIALS")

    case credentials_path do
      nil ->
        {:disabled, "GOOGLE_APPLICATION_CREDENTIALS not set"}

      path ->
        load_service_account(path)
    end
  end

  defp load_service_account(path) do
    with {:read, {:ok, body}} <- {:read, Elixir.File.read(path)},
         {:parse, {:ok, creds}} <- {:parse, Jason.decode(body)},
         {:validate, %{"client_email" => _}} <- {:validate, creds} do
      {:ready, :auth, %{creds: creds, scopes: @scopes}}
    else
      {:read, {:error, reason}} ->
        {:disabled, "read credentials #{inspect(path)}: #{inspect(reason)}"}

      {:parse, {:error, reason}} ->
        {:disabled, "parse credentials JSON: #{inspect(reason)}"}

      {:validate, _} ->
        {:disabled, "credentials JSON missing client_email"}
    end
  end
end
