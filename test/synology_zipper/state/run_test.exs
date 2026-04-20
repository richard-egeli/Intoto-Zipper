defmodule SynologyZipper.State.RunTest do
  use SynologyZipper.DataCase, async: true

  alias SynologyZipper.State.Run

  test "valid minimal run" do
    cs = Run.changeset(%Run{}, %{started_at: ~U[2024-06-01 00:00:00Z]})
    assert cs.valid?
  end

  test "started_at is required" do
    cs = Run.changeset(%Run{}, %{})
    refute cs.valid?
    assert Map.has_key?(errors_on(cs), :started_at)
  end

  test "rejects negative counts" do
    cs =
      Run.changeset(%Run{}, %{
        started_at: ~U[2024-06-01 00:00:00Z],
        months_zipped: -1,
        months_failed: 0
      })

    refute cs.valid?
    assert Map.has_key?(errors_on(cs), :months_zipped)
  end

  test "round-trip persists counts + notes" do
    attrs = %{
      started_at: ~U[2024-06-01 00:00:00Z],
      finished_at: ~U[2024-06-01 00:05:00Z],
      exit_status: "ok",
      months_zipped: 4,
      months_failed: 1,
      notes: "one upload failed"
    }

    {:ok, run} = %Run{} |> Run.changeset(attrs) |> Repo.insert()
    assert Repo.get!(Run, run.id).notes == "one upload failed"
  end
end
