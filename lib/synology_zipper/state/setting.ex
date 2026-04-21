defmodule SynologyZipper.State.Setting do
  @moduledoc """
  Single-row per-key config values (currently just `drive_credentials`:
  the raw JSON of a Google service-account key uploaded through the
  web UI). Uses the pre-existing `settings` table from the initial
  migration.

  Values are stored verbatim — parsing / validation happens in the
  State context at write time so this schema stays a thin key-value
  store.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "settings" do
    field :value, :string
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
  end
end
