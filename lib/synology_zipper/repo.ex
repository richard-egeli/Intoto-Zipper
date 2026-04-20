defmodule SynologyZipper.Repo do
  use Ecto.Repo,
    otp_app: :synology_zipper,
    adapter: Ecto.Adapters.SQLite3
end
