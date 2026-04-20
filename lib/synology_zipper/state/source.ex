defmodule SynologyZipper.State.Source do
  @moduledoc """
  A configured Synology folder to zip month-by-month.

  Mirrors the Go `config.Source` struct after migration 4 (no `delete`
  action) and migration 5 (per-source Drive folder). The struct doubles
  as the editable config row in SQLite — there is no separate YAML.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @post_zip_actions ~w(keep move)
  @month_re ~r/^\d{4}-(0[1-9]|1[0-2])$/

  @primary_key {:name, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :name}
  schema "sources" do
    field :path, :string
    field :start_month, :string
    field :grace_days, :integer, default: 3
    field :post_zip, :string, default: "keep"
    field :move_to, :string, default: ""
    # SQLite stores booleans as 0/1 integers with the sqlite3 adapter; we
    # expose the column as :boolean to get a native Elixir boolean.
    field :auto_upload, :boolean, default: false
    field :drive_folder_id, :string, default: ""
    field :created_at, :utc_datetime

    has_many :months, SynologyZipper.State.Month,
      foreign_key: :source_name,
      references: :name
  end

  @doc """
  Changeset for inserting or updating a source.

  Enforces the same invariants as the Go `validateSource`:
    * `name`, `path`, `start_month` required
    * `start_month` matches `YYYY-MM`
    * `grace_days >= 0`
    * `post_zip ∈ {keep, move}` (no `delete`)
    * `post_zip == "move"` implies `move_to != ""`
    * `auto_upload` implies `drive_folder_id != ""`
  """
  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :name,
      :path,
      :start_month,
      :grace_days,
      :post_zip,
      :move_to,
      :auto_upload,
      :drive_folder_id,
      :created_at
    ])
    |> validate_required([:name, :path, :start_month])
    |> validate_format(:start_month, @month_re, message: "must be YYYY-MM")
    |> validate_number(:grace_days, greater_than_or_equal_to: 0)
    |> validate_inclusion(:post_zip, @post_zip_actions,
      message: "must be one of: #{Enum.join(@post_zip_actions, ", ")}"
    )
    |> validate_move_to()
    |> validate_drive_folder_id()
    # sqlite3 adapter reports PK uniqueness as `<table>_<column>_index`.
    |> unique_constraint(:name, name: :sources_name_index)
  end

  @doc "Known post-zip actions after migration 4."
  def post_zip_actions, do: @post_zip_actions

  defp validate_move_to(changeset) do
    if get_field(changeset, :post_zip) == "move" and blank?(get_field(changeset, :move_to)) do
      add_error(changeset, :move_to, "is required when post_zip=move")
    else
      changeset
    end
  end

  defp validate_drive_folder_id(changeset) do
    if get_field(changeset, :auto_upload) == true and
         blank?(get_field(changeset, :drive_folder_id)) do
      add_error(changeset, :drive_folder_id, "is required when auto_upload=true")
    else
      changeset
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
