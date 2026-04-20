defmodule SynologyZipper.State.MonthTest do
  use SynologyZipper.DataCase, async: true

  alias SynologyZipper.State.{Month, Source}

  setup do
    {:ok, source} =
      %Source{}
      |> Source.changeset(%{name: "cams", path: "/srv/cams", start_month: "2024-01"})
      |> Repo.insert()

    %{source: source}
  end

  test "valid changeset accepts required fields", %{source: source} do
    cs =
      Month.changeset(%Month{}, %{
        source_name: source.name,
        month: "2024-05",
        status: "zipped",
        started_at: ~U[2024-06-01 00:00:00Z]
      })

    assert cs.valid?
  end

  test "rejects malformed month", %{source: source} do
    cs =
      Month.changeset(%Month{}, %{
        source_name: source.name,
        month: "2024-13",
        status: "zipped",
        started_at: ~U[2024-06-01 00:00:00Z]
      })

    refute cs.valid?
    assert Map.has_key?(errors_on(cs), :month)
  end

  test "rejects unknown status", %{source: source} do
    cs =
      Month.changeset(%Month{}, %{
        source_name: source.name,
        month: "2024-05",
        status: "weird",
        started_at: ~U[2024-06-01 00:00:00Z]
      })

    refute cs.valid?
    assert Map.has_key?(errors_on(cs), :status)
  end

  test "composite primary key uniqueness", %{source: source} do
    attrs = %{
      source_name: source.name,
      month: "2024-05",
      status: "zipped",
      started_at: ~U[2024-06-01 00:00:00Z]
    }

    {:ok, _} = %Month{} |> Month.changeset(attrs) |> Repo.insert()

    assert {:error, cs} =
             %Month{} |> Month.changeset(attrs) |> Repo.insert()

    refute cs.valid?
  end

  test "round-trip preserves upload columns", %{source: source} do
    attrs = %{
      source_name: source.name,
      month: "2024-05",
      status: "zipped",
      started_at: ~U[2024-06-01 00:00:00Z],
      finished_at: ~U[2024-06-01 00:10:00Z],
      zip_path: "/var/zips/cams/2024-05.zip",
      zip_bytes: 1024,
      file_count: 12,
      drive_file_id: "drive-abc",
      uploaded_at: ~U[2024-06-01 00:15:00Z],
      upload_error: "",
      upload_attempts: 1
    }

    {:ok, m} = %Month{} |> Month.changeset(attrs) |> Repo.insert()
    fetched = Repo.get_by!(Month, source_name: m.source_name, month: m.month)
    assert fetched.status == "zipped"
    assert fetched.drive_file_id == "drive-abc"
    assert fetched.upload_attempts == 1
    assert fetched.zip_bytes == 1024
  end
end
