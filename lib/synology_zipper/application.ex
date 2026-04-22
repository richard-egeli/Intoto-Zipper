defmodule SynologyZipper.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SynologyZipperWeb.Telemetry,
        SynologyZipper.Repo,
        # Migrate synchronously on every boot — single-instance Synology
        # deploy, so no blue/green contention. If you later go
        # multi-instance, move this to `/app/bin/migrate` and set
        # `skip: System.get_env("RELEASE_NAME") != nil`.
        {Ecto.Migrator,
         repos: Application.fetch_env!(:synology_zipper, :ecto_repos),
         skip: false},
        {DNSCluster, query: Application.get_env(:synology_zipper, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: SynologyZipper.PubSub},
        # HTTP client used by every google_api_drive / Goth call. Config
        # wires Tesla to this pool (see `config/config.exs`). Must start
        # before the Uploader so the first token fetch has a pool to
        # hand to Mint.
        {Finch, name: SynologyZipper.Finch},
        # Supervises async upload Tasks spawned by the Runner. Using a
        # Task.Supervisor + `async_nolink` is what keeps a crashing
        # upload (e.g. a timed-out GenServer.call) from tearing down the
        # whole run via Task.async's bidirectional link.
        {Task.Supervisor, name: SynologyZipper.UploadTaskSupervisor},
        SynologyZipperWeb.Endpoint
      ] ++ background_workers()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SynologyZipper.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Uploader + Scheduler are the two long-running singletons that make up
  # the backend. They're opt-in via application env so tests that want
  # isolated control (or that don't need them at all) can omit them with:
  #
  #     config :synology_zipper, :background_workers, false
  #
  # The integration test flips this on explicitly, with an in-test
  # Scheduler override that sets `tick_interval_ms` to a huge value so
  # nothing auto-ticks while tests are running.
  defp background_workers do
    if Application.get_env(:synology_zipper, :background_workers, true) do
      [
        {SynologyZipper.Uploader, uploader_opts()},
        {SynologyZipper.Scheduler, scheduler_opts()}
      ]
    else
      []
    end
  end

  defp uploader_opts do
    Application.get_env(:synology_zipper, SynologyZipper.Uploader, [])
  end

  defp scheduler_opts do
    Application.get_env(:synology_zipper, SynologyZipper.Scheduler, [])
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SynologyZipperWeb.Endpoint.config_change(changed, removed)
    :ok
  end

end
