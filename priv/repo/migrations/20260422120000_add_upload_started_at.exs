defmodule SynologyZipper.Repo.Migrations.AddUploadStartedAt do
  @moduledoc """
  Tracks when an upload is actively in flight for a given month. The
  runner sets this column just before dispatching the Drive request and
  clears it on success/failure. The scheduler's `init/1` sweeps every
  row on boot — if the app is starting, no upload can possibly be in
  flight, so any non-null value is a crashed/interrupted upload that
  the safety-net phase should retry on the next tick.

  Also lets the UI render "uploading…" across LiveView reloads without
  relying on an ephemeral PubSub event.
  """
  use Ecto.Migration

  def change do
    alter table(:months) do
      add :upload_started_at, :utc_datetime
    end
  end
end
