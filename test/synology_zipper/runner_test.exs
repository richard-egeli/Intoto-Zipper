defmodule SynologyZipper.RunnerTest do
  use SynologyZipper.DataCase, async: false

  alias SynologyZipper.{Runner, State, StubUploader}
  alias SynologyZipper.Uploader.Result, as: UResult

  defp write_file!(path, body) do
    Elixir.File.mkdir_p!(Path.dirname(path))
    Elixir.File.write!(path, body)
  end

  defp tmp_dir!(ctx) do
    path =
      Path.join(
        System.tmp_dir!(),
        "synz_runner_#{ctx}_#{System.unique_integer([:positive])}"
      )

    Elixir.File.mkdir_p!(path)
    on_exit(fn -> Elixir.File.rm_rf!(path) end)
    path
  end

  defp start_stub!(opts) do
    name = :"stub_#{System.unique_integer([:positive])}"
    {:ok, _} = StubUploader.start_link([name: name] ++ opts)
    {StubUploader, name}
  end

  test "single source: plans + zips eligible months, post-zip=keep" do
    source_path = tmp_dir!("src")
    # 2026-03 is eligible as of 2026-04-04 with grace_days=3.
    write_file!(Path.join([source_path, "2026-03-01", "a.mp4"]), "aaa")
    write_file!(Path.join([source_path, "2026-03-15", "b.mp4"]), "bbbb")

    {:ok, _} =
      State.upsert_source(%{
        name: "cams",
        path: source_path,
        start_month: "2026-03",
        grace_days: 3,
        auto_upload: false
      })

    stub = start_stub!(disabled: false, default: {:error, :unused})

    result = Runner.run(now: ~U[2026-04-04 00:00:00Z], uploader: stub)

    assert result.months_zipped == 1
    assert result.months_failed == 0
    assert result.exit_status == "ok"

    months = State.list_months("cams")
    assert [%{month: "2026-03", status: "zipped"}] = months

    # Source files are always kept after zipping.
    assert Elixir.File.exists?(Path.join([source_path, "2026-03-01", "a.mp4"]))
  end

  test "auto_upload: calls the uploader stub for zipped months" do
    source_path = tmp_dir!("src2")
    write_file!(Path.join([source_path, "2026-03-01", "a.mp4"]), "aaa")

    {:ok, _} =
      State.upsert_source(%{
        name: "cams",
        path: source_path,
        start_month: "2026-03",
        grace_days: 3,
        auto_upload: true,
        drive_folder_id: "folder-x"
      })

    plan = %{
      {"cams", "2026-03"} => {:ok, %UResult{drive_file_id: "FILE_1", bytes: 1, duration_ms: 5}}
    }

    stub = start_stub!(disabled: false, plan: plan, default: {:error, :unexpected_call})

    _ = Runner.run(now: ~U[2026-04-04 00:00:00Z], uploader: stub)

    month = State.get_month("cams", "2026-03")
    assert month.status == "zipped"
    assert month.drive_file_id == "FILE_1"
    assert month.upload_attempts == 1
    assert month.upload_error == ""

    # And the stub was called exactly once.
    assert StubUploader.calls(elem(stub, 1)) == [{"cams", "2026-03"}]
  end

  test "disabled uploader: marks every pending month with the disable reason, zipping unaffected" do
    source_path = tmp_dir!("src3")
    write_file!(Path.join([source_path, "2026-03-01", "a.mp4"]), "aaa")

    {:ok, _} =
      State.upsert_source(%{
        name: "cams",
        path: source_path,
        start_month: "2026-03",
        grace_days: 3,
        auto_upload: true,
        drive_folder_id: "folder-x"
      })

    stub = start_stub!(disabled: true, disabled_reason: "no creds")

    result = Runner.run(now: ~U[2026-04-04 00:00:00Z], uploader: stub)

    # Zipping succeeded.
    assert result.months_zipped == 1
    # Upload failure does NOT bump months_failed (Go invariant).
    assert result.months_failed == 0

    month = State.get_month("cams", "2026-03")
    assert month.drive_file_id == ""
    # `reason_string({:disabled, "no creds"})` unwraps the binary.
    assert month.upload_error == "no creds"
    assert month.upload_attempts == 1

    # The stub's `upload/2` short-circuits on `disabled: true` without
    # recording the call — mirrors the real Uploader, whose
    # `build_conn_from_db/0` returns `{:error, {:disabled, _}}` without
    # touching Drive.
    assert StubUploader.calls(elem(stub, 1)) == []
  end

  test "upload permanent error is recorded; zip row is not failed" do
    source_path = tmp_dir!("src4")
    write_file!(Path.join([source_path, "2026-03-01", "a.mp4"]), "aaa")

    {:ok, _} =
      State.upsert_source(%{
        name: "cams",
        path: source_path,
        start_month: "2026-03",
        grace_days: 3,
        auto_upload: true,
        drive_folder_id: "folder-x"
      })

    plan = %{
      {"cams", "2026-03"} => {:error, {:drive_error, 404, "nope"}}
    }

    stub = start_stub!(disabled: false, plan: plan)

    result = Runner.run(now: ~U[2026-04-04 00:00:00Z], uploader: stub)

    # 404 is not transient — one attempt, no retry loop sleeps.
    assert StubUploader.calls(elem(stub, 1)) == [{"cams", "2026-03"}]
    assert result.months_failed == 0
    assert result.months_zipped == 1

    month = State.get_month("cams", "2026-03")
    assert month.status == "zipped"
    assert month.drive_file_id == ""
    assert month.upload_error =~ "drive_error"
  end

  test "async upload crashing does not abort the whole run" do
    source_path = tmp_dir!("src_crash")
    # Two eligible months as of 2026-04-04 with grace_days=3.
    write_file!(Path.join([source_path, "2026-02-10", "a.mp4"]), "aaa")
    write_file!(Path.join([source_path, "2026-03-10", "b.mp4"]), "bbbb")

    {:ok, _} =
      State.upsert_source(%{
        name: "cams",
        path: source_path,
        start_month: "2026-02",
        grace_days: 3,
        auto_upload: true,
        drive_folder_id: "folder-x"
      })

    plan = %{
      {"cams", "2026-02"} => {:crash, :simulated_timeout},
      {"cams", "2026-03"} =>
        {:ok, %UResult{drive_file_id: "FILE_03", bytes: 1, duration_ms: 1}}
    }

    stub = start_stub!(disabled: false, plan: plan, default: {:error, :unexpected_call})

    result = Runner.run(now: ~U[2026-04-04 00:00:00Z], uploader: stub)

    assert result.months_zipped == 2
    assert result.months_failed == 0

    feb = State.get_month("cams", "2026-02")
    mar = State.get_month("cams", "2026-03")

    assert feb.status == "zipped"
    assert feb.drive_file_id == ""
    assert feb.upload_error =~ "simulated_timeout"

    assert mar.status == "zipped"
    assert mar.drive_file_id == "FILE_03"
    assert mar.upload_error == ""
  end

  test "source files are always kept after zipping" do
    source_path = tmp_dir!("src5")
    write_file!(Path.join([source_path, "2026-03-01", "a.mp4"]), "aaa")

    {:ok, _} =
      State.upsert_source(%{
        name: "cams",
        path: source_path,
        start_month: "2026-03",
        grace_days: 3,
        auto_upload: false
      })

    stub = start_stub!(disabled: false)

    _ = Runner.run(now: ~U[2026-04-04 00:00:00Z], uploader: stub)

    assert Elixir.File.exists?(Path.join([source_path, "2026-03-01", "a.mp4"]))
    assert Elixir.File.exists?(Path.join(source_path, "2026-03.zip"))
  end
end
