defmodule SynologyZipper.State.SourceTest do
  use SynologyZipper.DataCase, async: true

  alias SynologyZipper.State.Source

  @valid_attrs %{
    name: "cams",
    path: "/srv/video/cams",
    start_month: "2024-01",
    grace_days: 3,
    auto_upload: false,
    drive_folder_id: ""
  }

  describe "changeset/2" do
    test "accepts a minimal valid source" do
      cs = Source.changeset(%Source{}, @valid_attrs)
      assert cs.valid?
    end

    test "requires name, path, start_month" do
      cs = Source.changeset(%Source{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.path
      assert "can't be blank" in errors.start_month
    end

    test "rejects start_month not in YYYY-MM form" do
      for bad <- ["2024-1", "2024-13", "2024-00", "24-01", "not-a-month"] do
        cs = Source.changeset(%Source{}, %{@valid_attrs | start_month: bad})
        refute cs.valid?, "expected #{inspect(bad)} to be rejected"
        assert errors_on(cs).start_month |> Enum.any?(&String.contains?(&1, "YYYY-MM"))
      end
    end

    test "accepts well-formed start_month" do
      for good <- ["2024-01", "2024-12", "1999-06"] do
        cs = Source.changeset(%Source{}, %{@valid_attrs | start_month: good})
        assert cs.valid?, "expected #{inspect(good)} to be accepted"
      end
    end

    test "rejects negative grace_days" do
      cs = Source.changeset(%Source{}, %{@valid_attrs | grace_days: -1})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :grace_days)
    end

    test "auto_upload=true requires drive_folder_id" do
      cs =
        Source.changeset(%Source{}, %{
          @valid_attrs
          | auto_upload: true,
            drive_folder_id: ""
        })

      refute cs.valid?
      assert "is required when auto_upload=true" in errors_on(cs).drive_folder_id
    end

    test "auto_upload=true + drive_folder_id is accepted" do
      cs =
        Source.changeset(%Source{}, %{
          @valid_attrs
          | auto_upload: true,
            drive_folder_id: "1AbCdEf"
        })

      assert cs.valid?
    end
  end

  describe "persistence round-trip" do
    test "insert/read preserves all columns" do
      attrs =
        @valid_attrs
        |> Map.put(:auto_upload, true)
        |> Map.put(:drive_folder_id, "drive-folder-123")
        |> Map.put(:created_at, ~U[2024-05-01 00:00:00Z])

      assert {:ok, inserted} =
               %Source{}
               |> Source.changeset(attrs)
               |> Repo.insert()

      fetched = Repo.get!(Source, inserted.name)
      assert fetched.path == attrs.path
      assert fetched.start_month == attrs.start_month
      assert fetched.grace_days == 3
      assert fetched.auto_upload == true
      assert fetched.drive_folder_id == "drive-folder-123"
    end

    test "primary-key uniqueness on name" do
      {:ok, _} = %Source{} |> Source.changeset(@valid_attrs) |> Repo.insert()

      assert {:error, cs} =
               %Source{} |> Source.changeset(@valid_attrs) |> Repo.insert()

      refute cs.valid?
    end
  end
end
