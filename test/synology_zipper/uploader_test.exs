defmodule SynologyZipper.UploaderTest do
  use ExUnit.Case, async: true

  alias GoogleApi.Drive.V3.Connection, as: DriveConn
  alias SynologyZipper.Uploader
  alias SynologyZipper.Uploader.Job

  defp tmp_zip!(bytes) do
    path =
      Path.join(
        System.tmp_dir!(),
        "uploader_test_#{System.unique_integer([:positive])}.zip"
      )

    Elixir.File.write!(path, bytes)
    ExUnit.Callbacks.on_exit(fn -> Elixir.File.rm(path) end)
    md5 = :crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)
    {path, md5}
  end

  defp start_uploader!(opts) do
    name = :"uploader_#{System.unique_integer([:positive])}"
    {:ok, pid} = Uploader.start_link(Keyword.put(opts, :name, name))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  describe "disabled mode" do
    test "no credentials path -> :disabled; upload returns {:error, {:disabled, _}}" do
      # Unset the env so build_state falls into the nil branch.
      prev = System.get_env("GOOGLE_APPLICATION_CREDENTIALS")
      System.delete_env("GOOGLE_APPLICATION_CREDENTIALS")
      on_exit(fn -> if prev, do: System.put_env("GOOGLE_APPLICATION_CREDENTIALS", prev) end)

      server = start_uploader!(credentials_path: nil)

      assert Uploader.disabled?(server)
      assert is_binary(Uploader.disabled_reason(server))

      job = %Job{
        source_name: "cam",
        month: "2026-03",
        zip_path: "/tmp/nope.zip",
        drive_folder_id: "F"
      }

      assert {:error, {:disabled, reason}} = Uploader.upload(server, job)
      assert is_binary(reason)
    end

    test "credentials path pointing at a missing file -> :disabled" do
      server =
        start_uploader!(
          credentials_path: Path.join(System.tmp_dir!(), "definitely-not-here.json")
        )

      assert Uploader.disabled?(server)
    end
  end

  describe "ready mode (injected Tesla connection)" do
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
end
