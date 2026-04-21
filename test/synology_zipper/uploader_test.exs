defmodule SynologyZipper.UploaderTest do
  # Uses the SQL sandbox because the Uploader (in :dynamic mode) reads
  # credentials out of the DB.
  use SynologyZipper.DataCase, async: false

  alias GoogleApi.Drive.V3.Connection, as: DriveConn
  alias SynologyZipper.{State, Uploader}
  alias SynologyZipper.Uploader.Job

  defp tmp_zip!(bytes) do
    path =
      Path.join(
        System.tmp_dir!(),
        "uploader_test_#{System.unique_integer([:positive])}.zip"
      )

    Elixir.File.write!(path, bytes)
    on_exit(fn -> Elixir.File.rm(path) end)
    md5 = :crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)
    {path, md5}
  end

  defp start_uploader!(opts) do
    name = :"uploader_#{System.unique_integer([:positive])}"
    {:ok, pid} = Uploader.start_link(Keyword.put(opts, :name, name))

    # Allow the Uploader's process to use the test's sandboxed DB
    # connection — it queries State for credentials in :dynamic mode.
    Ecto.Adapters.SQL.Sandbox.allow(SynologyZipper.Repo, self(), pid)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    name
  end

  describe "dynamic mode (reads credentials from DB)" do
    test "disabled? is true when no credentials are stored" do
      server = start_uploader!([])
      assert Uploader.disabled?(server)

      reason = Uploader.disabled_reason(server)
      assert is_binary(reason)
      assert reason =~ "credentials"
    end

    test "upload returns {:error, {:disabled, _}} when no credentials are stored" do
      server = start_uploader!([])

      job = %Job{
        source_name: "cam",
        month: "2026-03",
        zip_path: "/tmp/nope.zip",
        drive_folder_id: "F"
      }

      assert {:error, {:disabled, _}} = Uploader.upload(server, job)
    end
  end

  describe "static_conn mode (conn injected by tests)" do
    test "delegates to Drive.upload/2 and returns the result" do
      body = "hello"
      {path, md5} = tmp_zip!(body)

      Tesla.Mock.mock(fn
        %{method: :get, url: "https://www.googleapis.com/drive/v3/files"} ->
          %Tesla.Env{
            status: 200,
            body: Jason.encode!(%{"files" => []})
          }

        %{method: :post, url: "https://www.googleapis.com/upload/drive/v3/files"} ->
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "id" => "FILE_OK",
                "md5Checksum" => md5,
                "size" => "#{byte_size(body)}"
              })
          }
      end)

      conn = DriveConn.new("fake-token")
      server = start_uploader!(conn: conn)

      refute Uploader.disabled?(server)
      assert Uploader.disabled_reason(server) == nil

      job = %Job{
        source_name: "cam",
        month: "2026-03",
        zip_path: path,
        drive_folder_id: "F"
      }

      assert {:ok, result} = Uploader.upload(server, job)
      assert result.drive_file_id == "FILE_OK"
    end
  end

  describe "reads fresh credentials on every upload in dynamic mode" do
    # Uploading-with-real-Goth-tokens requires hitting Google, so we
    # just prove that a stored credential flips disabled? from true to
    # false without restarting the GenServer. The actual token fetch
    # goes through Goth in prod; this test stops short of exercising
    # the HTTP call so we don't need to fake the token endpoint.
    test "disabled? flips to false after credentials are uploaded" do
      server = start_uploader!([])
      assert Uploader.disabled?(server)

      fake_creds =
        Jason.encode!(%{
          "client_email" => "svc@example.iam.gserviceaccount.com",
          "private_key" => "-----BEGIN PRIVATE KEY-----\nAAA\n-----END PRIVATE KEY-----\n"
        })

      {:ok, _} = State.put_drive_credentials(fake_creds)

      refute Uploader.disabled?(server)
      assert Uploader.disabled_reason(server) == nil
    end
  end
end
