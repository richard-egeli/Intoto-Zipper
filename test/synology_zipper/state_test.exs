defmodule SynologyZipper.StateTest do
  use SynologyZipper.DataCase, async: false

  alias SynologyZipper.State

  @source_attrs %{
    name: "cams",
    path: "/srv/video/cams",
    start_month: "2024-01"
  }

  describe "source CRUD" do
    test "upsert_source inserts then updates by name" do
      {:ok, a} = State.upsert_source(@source_attrs)
      assert a.path == "/srv/video/cams"

      {:ok, b} =
        State.upsert_source(%{
          @source_attrs
          | path: "/mnt/new"
        })

      assert b.name == "cams"
      assert b.path == "/mnt/new"
      assert length(State.list_sources()) == 1
    end

    test "upsert_source rejects when required fields are missing" do
      assert {:error, cs} =
               State.upsert_source(%{name: "bad", path: ""})

      refute cs.valid?
    end

    test "delete_source removes source and its months" do
      {:ok, _} = State.upsert_source(@source_attrs)
      {:ok, _} = State.start_month_attempt("cams", "2024-05", ~U[2024-06-01 00:00:00Z])
      assert length(State.list_months("cams")) == 1

      :ok = State.delete_source("cams")
      assert State.get_source("cams") == nil
      assert State.list_months("cams") == []
    end

    test "rename_source migrates month rows" do
      {:ok, _} = State.upsert_source(@source_attrs)
      {:ok, _} = State.start_month_attempt("cams", "2024-05", ~U[2024-06-01 00:00:00Z])

      assert {:ok, renamed} = State.rename_source("cams", "cams2")
      assert renamed.name == "cams2"
      assert State.get_source("cams") == nil
      assert State.get_source("cams2") != nil
      assert length(State.list_months("cams2")) == 1
      assert State.list_months("cams") == []
    end

    test "rename_source no-op when old == new" do
      {:ok, _} = State.upsert_source(@source_attrs)
      assert {:ok, _} = State.rename_source("cams", "cams")
    end

    test "rename_source conflict when target exists" do
      {:ok, _} = State.upsert_source(@source_attrs)
      {:ok, _} = State.upsert_source(%{@source_attrs | name: "other"})
      assert {:error, {:conflict, "other"}} = State.rename_source("cams", "other")
    end

    test "any_auto_upload?" do
      refute State.any_auto_upload?()

      {:ok, _} = State.upsert_source(@source_attrs)
      refute State.any_auto_upload?()

      {:ok, _} =
        State.upsert_source(%{
          name: "cams2",
          path: "/p",
          start_month: "2024-01",
          auto_upload: true,
          drive_folder_id: "fid"
        })

      assert State.any_auto_upload?()
    end
  end

  describe "month lifecycle" do
    setup do
      {:ok, source} = State.upsert_source(@source_attrs)
      %{source: source}
    end

    test "start_month_attempt inserts then increments attempt_count" do
      now = ~U[2024-06-01 00:00:00Z]
      {:ok, a} = State.start_month_attempt("cams", "2024-05", now)
      assert a.attempt_count == 1
      assert a.status == "failed"

      {:ok, b} = State.start_month_attempt("cams", "2024-05", now)
      assert b.attempt_count == 2
      assert b.status == "failed"
      assert b.error == nil
    end

    test "mark_zipped / mark_zipped_empty / mark_failed" do
      now = ~U[2024-06-01 00:00:00Z]
      {:ok, _} = State.start_month_attempt("cams", "2024-05", now)

      {:ok, zipped} =
        State.mark_zipped("cams", "2024-05", now, "/z/2024-05.zip", 1024, 3)

      assert zipped.status == "zipped"
      assert zipped.zip_bytes == 1024
      assert zipped.file_count == 3
      assert zipped.zip_path == "/z/2024-05.zip"

      {:ok, _} = State.start_month_attempt("cams", "2024-06", now)
      {:ok, empty} = State.mark_zipped_empty("cams", "2024-06", now)
      assert empty.status == "zipped"
      assert empty.zip_path == nil
      assert empty.file_count == 0

      {:ok, _} = State.start_month_attempt("cams", "2024-07", now)
      {:ok, failed} = State.mark_failed("cams", "2024-07", now, "disk full")
      assert failed.status == "failed"
      assert failed.error == "disk full"
    end

    test "zipped_months returns only status='zipped'" do
      now = ~U[2024-06-01 00:00:00Z]
      {:ok, _} = State.start_month_attempt("cams", "2024-05", now)
      {:ok, _} = State.mark_zipped("cams", "2024-05", now, "/z.zip", 1, 1)
      {:ok, _} = State.start_month_attempt("cams", "2024-06", now)
      {:ok, _} = State.mark_failed("cams", "2024-06", now, "err")

      result = State.zipped_months("cams")
      assert MapSet.member?(result, "2024-05")
      refute MapSet.member?(result, "2024-06")
    end

    test "reset_month deletes the row" do
      now = ~U[2024-06-01 00:00:00Z]
      {:ok, _} = State.start_month_attempt("cams", "2024-05", now)
      assert length(State.list_months("cams")) == 1

      :ok = State.reset_month("cams", "2024-05")
      assert State.list_months("cams") == []

      # idempotent
      :ok = State.reset_month("cams", "2024-05")
    end
  end

  describe "upload queries" do
    setup do
      {:ok, auto} =
        State.upsert_source(%{
          name: "auto",
          path: "/p",
          start_month: "2024-01",
          auto_upload: true,
          drive_folder_id: "folder-1"
        })

      {:ok, manual} = State.upsert_source(%{name: "manual", path: "/p", start_month: "2024-01"})

      now = ~U[2024-06-01 00:00:00Z]
      {:ok, _} = State.start_month_attempt("auto", "2024-05", now)
      {:ok, _} = State.mark_zipped("auto", "2024-05", now, "/z/auto-2024-05.zip", 100, 5)

      {:ok, _} = State.start_month_attempt("auto", "2024-06", now)
      {:ok, _} = State.mark_zipped_empty("auto", "2024-06", now)

      {:ok, _} = State.start_month_attempt("manual", "2024-05", now)
      {:ok, _} = State.mark_zipped("manual", "2024-05", now, "/z/manual.zip", 200, 10)

      %{auto: auto, manual: manual, now: now}
    end

    test "months_pending_upload filters to auto_upload=true + status=zipped + zip_path set" do
      pending = State.months_pending_upload()
      assert length(pending) == 1
      [row] = pending
      assert row.source_name == "auto"
      assert row.month == "2024-05"
      assert row.zip_path == "/z/auto-2024-05.zip"
      assert row.drive_folder_id == "folder-1"
    end

    test "mark_uploaded clears pending", %{now: now} do
      :ok = State.mark_uploaded("auto", "2024-05", "drive-file-1", now)
      assert State.months_pending_upload() == []

      m = State.get_month("auto", "2024-05")
      assert m.drive_file_id == "drive-file-1"
      assert m.uploaded_at == now
      assert m.upload_attempts == 1
      assert m.upload_error == ""
    end

    test "mark_upload_failed increments attempts and leaves it pending" do
      :ok = State.mark_upload_failed("auto", "2024-05", "503 retry")
      assert length(State.months_pending_upload()) == 1

      m = State.get_month("auto", "2024-05")
      assert m.drive_file_id == ""
      assert m.upload_attempts == 1
      assert m.upload_error == "503 retry"
    end

    test "mark_upload_started stamps upload_started_at and clears old error", %{now: now} do
      :ok = State.mark_upload_failed("auto", "2024-05", "stale 503")
      assert State.get_month("auto", "2024-05").upload_error == "stale 503"

      :ok = State.mark_upload_started("auto", "2024-05", now)

      m = State.get_month("auto", "2024-05")
      assert m.upload_started_at == now
      assert m.upload_error == ""
    end

    test "mark_uploaded clears upload_started_at", %{now: now} do
      :ok = State.mark_upload_started("auto", "2024-05", now)
      assert State.get_month("auto", "2024-05").upload_started_at == now

      :ok = State.mark_uploaded("auto", "2024-05", "drive-1", now)
      assert State.get_month("auto", "2024-05").upload_started_at == nil
    end

    test "mark_upload_failed clears upload_started_at", %{now: now} do
      :ok = State.mark_upload_started("auto", "2024-05", now)
      :ok = State.mark_upload_failed("auto", "2024-05", "boom")
      assert State.get_month("auto", "2024-05").upload_started_at == nil
    end

    test "clear_stale_upload_starts nulls upload_started_at everywhere and broadcasts", %{now: now} do
      :ok = State.subscribe_source("auto")
      :ok = State.mark_upload_started("auto", "2024-05", now)
      # Drain the :month_changed from mark_upload_started.
      assert_receive {:month_changed, "auto", "2024-05"}, 200

      assert State.get_month("auto", "2024-05").upload_started_at == now

      :ok = State.clear_stale_upload_starts()

      assert State.get_month("auto", "2024-05").upload_started_at == nil
      assert_receive {:month_changed, "auto", "2024-05"}, 200
    end

    test "months_pending_upload stops returning rows at the attempt cap" do
      cap = State.max_upload_attempts()

      # Bump attempts up to one below cap — still pending.
      for _ <- 1..(cap - 1), do: :ok = State.mark_upload_failed("auto", "2024-05", "flaky")
      assert [_] = State.months_pending_upload()

      # One more pushes it to the cap — safety net stops picking it up.
      :ok = State.mark_upload_failed("auto", "2024-05", "flaky")
      assert State.months_pending_upload() == []

      m = State.get_month("auto", "2024-05")
      assert m.upload_attempts == cap
      assert m.upload_error == "flaky"
    end
  end

  describe "runs" do
    test "start_run + finish_run + list_runs" do
      started = ~U[2024-06-01 00:00:00Z]
      finished = ~U[2024-06-01 00:05:00Z]
      r = State.start_run(started)
      assert r.started_at == started

      updated = State.finish_run(r.id, finished, "ok", 3, 1, "note")
      assert updated.months_zipped == 3
      assert updated.months_failed == 1
      assert updated.exit_status == "ok"
      assert updated.notes == "note"

      [latest | _] = State.list_runs(50)
      assert latest.id == r.id
    end

    test "list_runs limit defaults to 50 and rejects non-positive" do
      for _ <- 1..3, do: State.start_run(~U[2024-06-01 00:00:00Z])
      assert length(State.list_runs(0)) <= 50
      assert length(State.list_runs(-1)) <= 50
      assert length(State.list_runs(2)) == 2
    end
  end

  describe "PubSub broadcasts" do
    test "upsert_source broadcasts to sources + per-source topic" do
      :ok = State.subscribe_sources()
      :ok = State.subscribe_source("cams")

      {:ok, _} = State.upsert_source(@source_attrs)

      assert_receive {:source_changed, "cams"}
      assert_receive {:source_changed, "cams"}
    end

    test "delete_source broadcasts deletion" do
      {:ok, _} = State.upsert_source(@source_attrs)
      :ok = State.subscribe_sources()

      :ok = State.delete_source("cams")
      assert_receive {:source_deleted, "cams"}
    end

    test "month mutations broadcast month_changed" do
      {:ok, _} = State.upsert_source(@source_attrs)
      :ok = State.subscribe_source("cams")

      now = ~U[2024-06-01 00:00:00Z]
      {:ok, _} = State.start_month_attempt("cams", "2024-05", now)
      assert_receive {:month_changed, "cams", "2024-05"}

      {:ok, _} = State.mark_zipped("cams", "2024-05", now, "/z.zip", 1, 1)
      assert_receive {:month_changed, "cams", "2024-05"}

      :ok = State.reset_month("cams", "2024-05")
      assert_receive {:month_deleted, "cams", "2024-05"}
    end

    test "run broadcasts" do
      :ok = State.subscribe_runs()
      r = State.start_run(~U[2024-06-01 00:00:00Z])
      assert_receive {:run_changed, id}
      assert id == r.id
    end
  end

  describe "drive credentials" do
    @valid_creds %{
      "client_email" => "svc@example.iam.gserviceaccount.com",
      "private_key" => "-----BEGIN PRIVATE KEY-----\nAAA\n-----END PRIVATE KEY-----\n"
    }

    test "get_drive_credentials returns nil when nothing is stored" do
      assert State.get_drive_credentials() == nil
      assert State.get_drive_credentials_email() == nil
    end

    test "put_drive_credentials stores and get returns the parsed map" do
      json = Jason.encode!(@valid_creds)
      assert {:ok, _} = State.put_drive_credentials(json)

      assert State.get_drive_credentials() == @valid_creds
      assert State.get_drive_credentials_email() == @valid_creds["client_email"]
    end

    test "put_drive_credentials replaces existing credentials on re-upload" do
      first = Jason.encode!(Map.put(@valid_creds, "client_email", "first@example.iam.gserviceaccount.com"))
      second = Jason.encode!(Map.put(@valid_creds, "client_email", "second@example.iam.gserviceaccount.com"))

      assert {:ok, _} = State.put_drive_credentials(first)
      assert {:ok, _} = State.put_drive_credentials(second)

      assert State.get_drive_credentials_email() == "second@example.iam.gserviceaccount.com"
    end

    test "put_drive_credentials rejects invalid JSON" do
      assert {:error, :invalid_json} = State.put_drive_credentials("{not json")
      assert State.get_drive_credentials() == nil
    end

    test "put_drive_credentials rejects JSON missing client_email" do
      json = Jason.encode!(Map.delete(@valid_creds, "client_email"))
      assert {:error, :missing_required_fields} = State.put_drive_credentials(json)
    end

    test "put_drive_credentials rejects JSON missing private_key" do
      json = Jason.encode!(Map.delete(@valid_creds, "private_key"))
      assert {:error, :missing_required_fields} = State.put_drive_credentials(json)
    end

    test "delete_drive_credentials removes the stored credentials" do
      json = Jason.encode!(@valid_creds)
      {:ok, _} = State.put_drive_credentials(json)
      assert State.get_drive_credentials() != nil

      :ok = State.delete_drive_credentials()
      assert State.get_drive_credentials() == nil
      assert State.get_drive_credentials_email() == nil
    end

    test "delete is idempotent when nothing is stored" do
      assert :ok = State.delete_drive_credentials()
      assert :ok = State.delete_drive_credentials()
    end

    test "put/delete broadcast :settings_changed" do
      :ok = State.subscribe_settings()

      {:ok, _} = State.put_drive_credentials(Jason.encode!(@valid_creds))
      assert_receive :settings_changed

      :ok = State.delete_drive_credentials()
      assert_receive :settings_changed
    end
  end

  describe "list_sources_with_stats" do
    test "returns derived columns" do
      {:ok, _} =
        State.upsert_source(%{
          name: "auto",
          path: "/p",
          start_month: "2024-01",
          auto_upload: true,
          drive_folder_id: "fid"
        })

      now = ~U[2024-06-01 00:00:00Z]
      {:ok, _} = State.start_month_attempt("auto", "2024-05", now)
      {:ok, _} = State.mark_zipped("auto", "2024-05", now, "/z.zip", 1, 1)
      :ok = State.mark_uploaded("auto", "2024-05", "drive-1", now)

      {:ok, _} = State.start_month_attempt("auto", "2024-06", now)
      {:ok, _} = State.mark_zipped("auto", "2024-06", now, "/z2.zip", 1, 1)
      :ok = State.mark_upload_failed("auto", "2024-06", "network")

      {:ok, _} = State.start_month_attempt("auto", "2024-07", now)
      {:ok, _} = State.mark_failed("auto", "2024-07", now, "bad")

      [row] = State.list_sources_with_stats()
      assert row.name == "auto"
      assert row.last_zipped_month == "2024-06"
      assert row.zipped_months == 2
      assert row.uploaded_months == 1
      assert row.failed_uploads == 1
    end
  end

end
