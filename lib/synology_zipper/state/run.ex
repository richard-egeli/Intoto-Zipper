defmodule SynologyZipper.State.Run do
  @moduledoc """
  One scheduler tick. Inserted at the start of a run and finalised
  afterwards with counts + exit status. Mirrors the Go `runs` table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "runs" do
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :exit_status, :string
    field :months_zipped, :integer, default: 0
    field :months_failed, :integer, default: 0
    field :notes, :string
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:started_at, :finished_at, :exit_status, :months_zipped, :months_failed, :notes])
    |> validate_required([:started_at])
    |> validate_number(:months_zipped, greater_than_or_equal_to: 0)
    |> validate_number(:months_failed, greater_than_or_equal_to: 0)
  end
end
