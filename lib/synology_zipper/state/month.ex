defmodule SynologyZipper.State.Month do
  @moduledoc """
  One month's worth of state for a single source.

  Composite primary key `(source_name, month)`; matches the Go
  `months` table after all 5 legacy migrations including the Drive
  upload columns from migration 5.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(zipped failed)

  @primary_key false
  schema "months" do
    field :source_name, :string, primary_key: true
    field :month, :string, primary_key: true
    field :status, :string
    field :zip_path, :string
    field :zip_bytes, :integer
    field :file_count, :integer
    field :attempt_count, :integer, default: 0
    field :last_attempt_at, :utc_datetime
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :error, :string

    # Upload state.
    field :drive_file_id, :string, default: ""
    field :uploaded_at, :utc_datetime
    field :upload_error, :string, default: ""
    field :upload_attempts, :integer, default: 0

    belongs_to :source, SynologyZipper.State.Source,
      foreign_key: :source_name,
      references: :name,
      type: :string,
      define_field: false
  end

  @doc """
  Changeset used by the State context when writing month rows. The
  context normally crafts narrow updates (e.g. `mark_zipped`), so this
  changeset exists mainly for tests and the initial insert path.
  """
  def changeset(month, attrs) do
    month
    |> cast(attrs, [
      :source_name,
      :month,
      :status,
      :zip_path,
      :zip_bytes,
      :file_count,
      :attempt_count,
      :last_attempt_at,
      :started_at,
      :finished_at,
      :error,
      :drive_file_id,
      :uploaded_at,
      :upload_error,
      :upload_attempts
    ])
    |> validate_required([:source_name, :month, :status, :started_at])
    |> validate_format(:month, ~r/^\d{4}-(0[1-9]|1[0-2])$/, message: "must be YYYY-MM")
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:source_name, :month], name: :months_source_name_month_index)
  end

  def valid_statuses, do: @valid_statuses
end
