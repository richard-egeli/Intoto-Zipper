defmodule SynologyZipper.Repo.Migrations.InitialSchema do
  @moduledoc """
  Initial schema — folds the 5 Go-era migrations into one.

  Column set matches `internal/state/schema.go` after all 5 legacy
  migrations: no `delete` post-zip action, per-source `grace_days`,
  and the auto-upload Drive columns live directly on the relevant
  rows.
  """
  use Ecto.Migration

  def change do
    create table(:sources, primary_key: false) do
      add :name, :text, primary_key: true
      add :path, :text, null: false
      add :start_month, :text, null: false
      add :grace_days, :integer, null: false, default: 3
      add :post_zip, :text, null: false, default: "keep"
      add :move_to, :text, null: false, default: ""
      add :auto_upload, :integer, null: false, default: 0
      add :drive_folder_id, :text, null: false, default: ""
      add :created_at, :utc_datetime, null: false, default: fragment("CURRENT_TIMESTAMP")
    end

    create table(:months, primary_key: false) do
      add :source_name, references(:sources, column: :name, type: :text, on_delete: :nothing),
        null: false,
        primary_key: true

      add :month, :text, null: false, primary_key: true
      add :status, :text, null: false
      add :zip_path, :text
      add :zip_bytes, :integer
      add :file_count, :integer
      add :attempt_count, :integer, null: false, default: 0
      add :last_attempt_at, :utc_datetime
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :error, :text

      # Upload state (null when never attempted).
      add :drive_file_id, :text, null: false, default: ""
      add :uploaded_at, :utc_datetime
      add :upload_error, :text, null: false, default: ""
      add :upload_attempts, :integer, null: false, default: 0
    end

    create unique_index(:months, [:source_name, :month], name: :months_source_name_month_index)

    create table(:runs) do
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :exit_status, :text
      add :months_zipped, :integer, null: false, default: 0
      add :months_failed, :integer, null: false, default: 0
      add :notes, :text
    end

    # Kept for parity with Go migration 2 — may be repurposed later.
    create table(:settings, primary_key: false) do
      add :key, :text, primary_key: true
      add :value, :text, null: false
    end
  end
end
