defmodule SynologyZipper.Uploader.DriveTest do
  use ExUnit.Case, async: true

  alias GoogleApi.Drive.V3.Connection, as: DriveConn
  alias SynologyZipper.Uploader.{Drive, Job}

  @folder_id "FOLDER_ID"

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp conn, do: DriveConn.new("fake-token")

  defp tmp_zip!(bytes) do
    path =
      Path.join(
        System.tmp_dir!(),
        "drive_test_#{System.unique_integer([:positive])}.zip"
      )

    Elixir.File.write!(path, bytes)
    ExUnit.Callbacks.on_exit(fn -> Elixir.File.rm(path) end)
    md5 = :crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)
    {path, md5}
  end

  defp job(path),
    do: %Job{
      source_name: "cam",
      month: "2026-03",
      zip_path: path,
      drive_folder_id: @folder_id
    }

  defp json(body) do
    # google_gax decodes via Poison; the body must be a JSON string, not
    # a raw map, otherwise its JSON middleware raises a ParseError.
    %Tesla.Env{
      status: 200,
      headers: [{"content-type", "application/json"}],
      body: Jason.encode!(body)
    }
  end

  defp error_json(status, message) do
    %Tesla.Env{
      status: status,
      headers: [{"content-type", "application/json"}],
      body: Jason.encode!(%{"error" => %{"code" => status, "message" => message}})
    }
  end

  # Records (path, method) for every mocked request so tests can assert
  # absence of forbidden calls. Uses a per-test agent keyed in the pdict.
  defp track!(fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    Process.put(:drive_test_agent, agent)

    mock = fn env ->
      Agent.update(agent, &[{env.method, env.url} | &1])
      fun.(env)
    end

    Tesla.Mock.mock(mock)
    ExUnit.Callbacks.on_exit(fn -> Process.delete(:drive_test_agent) end)
    agent
  end

  defp calls(agent), do: Agent.get(agent, &Enum.reverse/1)

  defp seen(agent, method) do
    agent
    |> calls()
    |> Enum.count(fn {m, _} -> m == method end)
  end

  # ---------------------------------------------------------------------------
  # Success path
  # ---------------------------------------------------------------------------

  describe "upload/2 — success" do
    test "lists empty, uploads, md5 matches → returns drive_file_id" do
      body = "hello world zip content"
      {path, md5} = tmp_zip!(body)

      agent =
        track!(fn env ->
          case {env.method, env.url} do
            {:get, "https://www.googleapis.com/drive/v3/files"} ->
              json(%{"files" => []})

            {:post, "https://www.googleapis.com/upload/drive/v3/files"} ->
              json(%{
                "id" => "FILE_OK",
                "md5Checksum" => md5,
                "size" => "#{byte_size(body)}"
              })
          end
        end)

      assert {:ok, result} = Drive.upload(conn(), job(path))
      assert result.drive_file_id == "FILE_OK"
      assert result.bytes == byte_size(body)
      assert seen(agent, :delete) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Md5 mismatch after create → delete
  # ---------------------------------------------------------------------------

  describe "upload/2 — md5 mismatch after create" do
    test "deletes the just-created file and returns a permanent error" do
      {path, _} = tmp_zip!("the local bytes")

      agent =
        track!(fn env ->
          case {env.method, env.url} do
            {:get, "https://www.googleapis.com/drive/v3/files"} ->
              json(%{"files" => []})

            {:post, "https://www.googleapis.com/upload/drive/v3/files"} ->
              json(%{"id" => "BAD_FILE", "md5Checksum" => "deadbeefdeadbeefdeadbeefdeadbeef"})

            {:delete, "https://www.googleapis.com/drive/v3/files/BAD_FILE"} ->
              %Tesla.Env{status: 204, body: ""}
          end
        end)

      assert {:error, {:md5_mismatch, _local, "deadbeefdeadbeefdeadbeefdeadbeef"}} =
               Drive.upload(conn(), job(path))

      assert seen(agent, :delete) == 1
      refute Drive.transient?({:md5_mismatch, "a", "b"})
    end
  end

  # ---------------------------------------------------------------------------
  # Drive returns 404 / 503
  # ---------------------------------------------------------------------------

  describe "upload/2 — drive errors" do
    test "404 on list is permanent" do
      {path, _} = tmp_zip!("x")

      track!(fn %{method: :get} -> error_json(404, "File not found: F") end)

      assert {:error, {:drive_error, 404, _}} = Drive.upload(conn(), job(path))
      refute Drive.transient?({:drive_error, 404, "nf"})
    end

    test "503 on list is transient" do
      {path, _} = tmp_zip!("x")

      track!(fn %{method: :get} -> error_json(503, "backend unavailable") end)

      assert {:error, {:drive_error, 503, _}} = Drive.upload(conn(), job(path))
      assert Drive.transient?({:drive_error, 503, "nu"})
    end
  end

  # ---------------------------------------------------------------------------
  # Local zip missing
  # ---------------------------------------------------------------------------

  describe "upload/2 — local zip missing" do
    test "returns :local_zip_missing without calling create" do
      missing = Path.join(System.tmp_dir!(), "definitely-not-here.zip")

      agent =
        track!(fn %{method: :get} -> json(%{"files" => []}) end)

      assert {:error, {:local_zip_missing, ^missing}} = Drive.upload(conn(), job(missing))
      assert seen(agent, :post) == 0
      refute Drive.transient?({:local_zip_missing, missing})
    end
  end

  # ---------------------------------------------------------------------------
  # Orphan adoption paths
  # ---------------------------------------------------------------------------

  describe "upload/2 — orphan adoption" do
    test "exactly one match with matching md5 is adopted (no POST / no DELETE)" do
      body = "the zip bytes that were uploaded earlier"
      {path, md5} = tmp_zip!(body)

      agent =
        track!(fn %{method: :get} ->
          json(%{
            "files" => [
              %{
                "id" => "ORPHAN_ID",
                "name" => "2026-03.zip",
                "md5Checksum" => md5,
                "size" => "#{byte_size(body)}"
              }
            ]
          })
        end)

      assert {:ok, result} = Drive.upload(conn(), job(path))
      assert result.drive_file_id == "ORPHAN_ID"
      assert seen(agent, :post) == 0
      assert seen(agent, :delete) == 0
    end

    test "exactly one match with mismatched md5 is rejected" do
      {path, _} = tmp_zip!("our new local content")

      agent =
        track!(fn %{method: :get} ->
          json(%{
            "files" => [
              %{
                "id" => "STALE_ID",
                "name" => "2026-03.zip",
                "md5Checksum" => "deadbeefdeadbeefdeadbeefdeadbeef",
                "size" => "99"
              }
            ]
          })
        end)

      assert {:error, {:orphan_md5_mismatch, %{file_id: "STALE_ID"}}} =
               Drive.upload(conn(), job(path))

      assert seen(agent, :post) == 0
      assert seen(agent, :delete) == 0
      refute Drive.transient?({:orphan_md5_mismatch, %{}})
    end

    test "multiple matches yields :ambiguous_orphan" do
      {path, _} = tmp_zip!("whatever")

      agent =
        track!(fn %{method: :get} ->
          json(%{
            "files" => [
              %{"id" => "FIRST", "name" => "2026-03.zip", "md5Checksum" => "a"},
              %{"id" => "SECOND", "name" => "2026-03.zip", "md5Checksum" => "b"}
            ]
          })
        end)

      assert {:error, {:ambiguous_orphan, ids}} = Drive.upload(conn(), job(path))
      assert "FIRST" in ids
      assert "SECOND" in ids
      assert seen(agent, :post) == 0
      assert seen(agent, :delete) == 0
      refute Drive.transient?({:ambiguous_orphan, ids})
    end
  end

  # ---------------------------------------------------------------------------
  # transient? table
  # ---------------------------------------------------------------------------

  describe "transient?/1" do
    test "Drive 4xx permanent, 5xx + 429 transient" do
      for code <- [400, 401, 403, 404] do
        refute Drive.transient?({:drive_error, code, "m"}), "code #{code} must be permanent"
      end

      for code <- [429, 500, 502, 503, 504] do
        assert Drive.transient?({:drive_error, code, "m"}), "code #{code} must be transient"
      end
    end

    test ":disabled is permanent" do
      refute Drive.transient?(:disabled)
    end

    test "unknown transport errors are transient" do
      assert Drive.transient?({:transport, :nxdomain})
    end
  end
end
