defmodule SynologyZipper.Uploader do
  @moduledoc """
  GenServer that owns the Drive API `Tesla.Client` (authenticated via
  Goth) and serves `upload/2` requests serially.

  State is one of:

    * `{:ready, conn}` — service account credentials loaded, ready to
      upload;
    * `{:disabled, reason}` — no usable credentials; every `upload/2`
      returns `{:error, :disabled}`. Logged once at startup so the UI
      can surface a banner.

  Ports `internal/uploader/client.go` + `uploader.go`.

  *This module does not retry.* The runner wraps each call in
  `SynologyZipper.Retry.run/3` using `Drive.transient?/1`.
  """

  use GenServer

  require Logger

  alias SynologyZipper.Uploader.{Drive, Job}

  @name __MODULE__
  @default_timeout :timer.minutes(15)

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
        conn -> {:ready, conn}
      end

    case state do
      {:ready, _} ->
        Logger.info("drive uploader ready")

      {:disabled, reason} ->
        Logger.warning("drive uploader disabled", reason: reason)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:upload, job}, _from, {:ready, conn} = state) do
    {:reply, Drive.upload(conn, job), state}
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
         {:ok, conn} <- build_conn(creds) do
      {:ready, conn}
    else
      {:read, {:error, reason}} ->
        {:disabled, "read credentials #{inspect(path)}: #{inspect(reason)}"}

      {:parse, {:error, reason}} ->
        {:disabled, "parse credentials JSON: #{inspect(reason)}"}

      {:error, reason} ->
        {:disabled, "init drive client: #{inspect(reason)}"}
    end
  end

  defp build_conn(%{"client_email" => _} = creds) do
    # Static token for now — a Goth server can be introduced once
    # runtime plumbing lands (Task 7). The Drive client itself is
    # ready either way.
    scopes = ["https://www.googleapis.com/auth/drive.file"]

    source = {:service_account, creds, scopes: scopes}

    try do
      {:ok, token} = Goth.Token.fetch(source: source)
      {:ok, GoogleApi.Drive.V3.Connection.new(token.token)}
    rescue
      e -> {:error, e}
    catch
      _, reason -> {:error, reason}
    end
  end

  defp build_conn(_), do: {:error, :missing_client_email}
end
