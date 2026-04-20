import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :synology_zipper, SynologyZipper.Repo,
  database: Path.expand("../synology_zipper_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :synology_zipper, SynologyZipperWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "V5KhIfaloP9HkK+weU3srJIs0kQA+RAUhg4rAZJT71oVok/moPZ7S5ABaBmvVPg4",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Keep metadata visible in test log output so the integration test
# surfaces zipper reasons, etc.
config :logger, :console, metadata: :all

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Every Tesla client in tests (including google_api_drive's) routes
# through Tesla.Mock so that no real HTTP ever happens.
config :tesla, adapter: Tesla.Mock

# Don't auto-start the Uploader + Scheduler during `mix test`. Most
# tests use `DataCase` which uses the SQL sandbox; the background
# Scheduler would fight for its own checkout. The integration test
# starts its own supervised instances explicitly.
config :synology_zipper, :background_workers, false
