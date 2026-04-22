# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :synology_zipper,
  ecto_repos: [SynologyZipper.Repo],
  generators: [timestamp_type: :utc_datetime]

# Start the Uploader + Scheduler by default. Tests override this to
# false in config/test.exs so each test boots its own isolated
# instances (or none at all).
config :synology_zipper, :background_workers, true

# Scheduler default — 1 hour tick in prod; dev / prod overrides live in
# their respective config files or in config/runtime.exs.
# initial_delay_ms must be > 0 — Scheduler.schedule_next_tick/1 treats 0
# as "skip scheduling", which prevents the recurring tick chain from ever
# starting (the first :tick is what arms the next one). Tests that want
# "manual runs only" pass initial_delay_ms: 0 explicitly in opts.
config :synology_zipper, SynologyZipper.Scheduler,
  tick_interval_ms: 60 * 60 * 1000,
  initial_delay_ms: 1_000

# Configures the endpoint
config :synology_zipper, SynologyZipperWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SynologyZipperWeb.ErrorHTML, json: SynologyZipperWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SynologyZipper.PubSub,
  live_view: [signing_salt: "21vc9lop"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  synology_zipper: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  synology_zipper: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Silence the Tesla.Builder deprecation warning triggered by the
# google_api_drive SDK — we don't define our own Tesla clients.
config :tesla, disable_deprecated_builder_warning: true

# Use Finch as the Tesla adapter so every google_api_drive / Goth call
# goes through the named pool started in `SynologyZipper.Application`.
# Tesla's built-in default is `:httpc`, whose receive-side timeout for a
# multi-hour streamed upload is effectively infinite — a stalled TCP
# socket would hang the Uploader's call forever. Finch exposes
# `receive_timeout`, which is the max time we wait for the server to
# send the next chunk after we've sent the request body. 30 minutes is
# far larger than any real Drive-side ACK latency but small enough to
# trip on a truly dead socket. Uploads themselves may take hours; that
# time is governed by send throughput, not receive_timeout.
# `config/test.exs` overrides this with `Tesla.Mock`.
config :tesla, :adapter,
  {Tesla.Adapter.Finch, name: SynologyZipper.Finch, receive_timeout: :timer.minutes(30)}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
