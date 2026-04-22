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

  describe "concurrent probes during an in-flight upload" do
    # Regression: the GenServer used to run `Drive.upload/2` inline
    # inside `handle_call`, holding the mailbox for the full upload
    # duration (hours in prod). Post-rework, the call spawns a Task and
    # returns `:noreply`; `disabled?` / `disabled_reason` handlers reply
    # immediately regardless of whether an upload is in flight.
    test "disabled? returns without waiting for an active upload" do
      body = "hello"
      {path, md5} = tmp_zip!(body)

      parent = self()

      Tesla.Mock.mock(fn
        %{method: :get, url: "https://www.googleapis.com/drive/v3/files"} ->
          %Tesla.Env{
            status: 200,
            body: Jason.encode!(%{"files" => []})
          }

        %{method: :post, url: "https://www.googleapis.com/upload/drive/v3/files"} ->
          # Tell the test we're in and block until explicitly released.
          send(parent, {:upload_entered, self()})

          receive do
            :release ->
              %Tesla.Env{
                status: 200,
                body:
                  Jason.encode!(%{
                    "id" => "FILE_OK",
                    "md5Checksum" => md5,
                    "size" => "#{byte_size(body)}"
                  })
              }
          after
            5_000 -> %Tesla.Env{status: 500, body: ""}
          end
      end)

      conn = DriveConn.new("fake-token")
      server = start_uploader!(conn: conn)

      job = %Job{
        source_name: "cam",
        month: "2026-03",
        zip_path: path,
        drive_folder_id: "F"
      }

      upload_task = Task.async(fn -> Uploader.upload(server, job) end)

      # Wait until the Uploader has dispatched the work and the mock is
      # actually blocked mid-upload.
      assert_receive {:upload_entered, mock_pid}, 1_000

      # The upload is genuinely in flight; `disabled?` must still return
      # immediately. Budget 200ms — plenty for a synchronous reply from a
      # local GenServer, far below anything that would mask a regression.
      start = System.monotonic_time(:millisecond)
      refute Uploader.disabled?(server)
      assert Uploader.disabled_reason(server) == nil
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 200,
             "probes should be non-blocking during an upload; took #{elapsed}ms"

      # Release the upload and confirm the original call still returns
      # the real result — the rework must not drop replies.
      send(mock_pid, :release)
      assert {:ok, %{drive_file_id: "FILE_OK"}} = Task.await(upload_task, 2_000)
    end

    test "second upload can be submitted while first is in flight" do
      # The single-worker serialization is still a semantic goal — two
      # uploads to Drive should not run in parallel. What we don't want
      # is the SECOND `GenServer.call` to block the test's own mailbox
      # for the duration of the first upload.
      body = "hello"
      {path, md5} = tmp_zip!(body)
      parent = self()

      Tesla.Mock.mock(fn
        %{method: :get, url: "https://www.googleapis.com/drive/v3/files"} ->
          %Tesla.Env{status: 200, body: Jason.encode!(%{"files" => []})}

        %{method: :post, url: "https://www.googleapis.com/upload/drive/v3/files"} ->
          send(parent, {:mock_hit, self()})

          receive do
            :release ->
              %Tesla.Env{
                status: 200,
                body:
                  Jason.encode!(%{
                    "id" => "FILE",
                    "md5Checksum" => md5,
                    "size" => "#{byte_size(body)}"
                  })
              }
          after
            5_000 -> %Tesla.Env{status: 500, body: ""}
          end
      end)

      conn = DriveConn.new("fake-token")
      server = start_uploader!(conn: conn)
      job = %Job{source_name: "cam", month: "2026-01", zip_path: path, drive_folder_id: "F"}

      first = Task.async(fn -> Uploader.upload(server, job) end)
      assert_receive {:mock_hit, first_mock_pid}, 1_000

      # Second call: submitting it must not wait for the first's upload.
      second =
        Task.async(fn ->
          Uploader.upload(server, %{job | month: "2026-02"})
        end)

      # Release the first — second should then run through the mock.
      send(first_mock_pid, :release)
      assert_receive {:mock_hit, second_mock_pid}, 2_000
      send(second_mock_pid, :release)

      assert {:ok, %{drive_file_id: "FILE"}} = Task.await(first, 2_000)
      assert {:ok, %{drive_file_id: "FILE"}} = Task.await(second, 2_000)
    end
  end

  describe "concurrent-call timeout behaviour" do
    # Regression: `disabled?` and `disabled_reason` previously used the
    # default 5_000ms `GenServer.call` timeout. Because every public call
    # on this module is serialised through the same mailbox, a preflight
    # probe fired from task N+1 while task N's `upload` was still
    # in-flight would queue behind it and exit at 5s. The runner's
    # `catch kind, reason` then recorded the timeout as a failed upload
    # on an otherwise healthy month. `:infinity` lets the probes queue
    # for as long as the in-flight upload needs — the transport-side
    # HTTP timeout remains the real bound.
    test "disabled? and disabled_reason don't exit when the GenServer is busy" do
      server = start_uploader!([])
      server_pid = Process.whereis(server)

      :sys.suspend(server_pid)
      on_exit(fn -> if Process.alive?(server_pid), do: :sys.resume(server_pid) end)

      parent = self()

      safe = fn fun ->
        try do
          {:ok, fun.()}
        catch
          kind, reason -> {kind, reason}
        end
      end

      spawn(fn -> send(parent, {:disabled, safe.(fn -> Uploader.disabled?(server) end)}) end)
      spawn(fn -> send(parent, {:reason, safe.(fn -> Uploader.disabled_reason(server) end)}) end)

      # Pre-fix: both probes exit at the default 5_000ms GenServer.call
      # timeout and land in our mailbox as `{_, {:exit, {:timeout, ...}}}`.
      # Post-fix: nothing is delivered; the calls stay queued.
      Process.sleep(5_100)
      refute_received {:disabled, _}
      refute_received {:reason, _}

      :sys.resume(server_pid)

      assert_receive {:disabled, {:ok, true}}, 2_000
      assert_receive {:reason, {:ok, reason}}, 2_000
      assert is_binary(reason)
      assert reason =~ "credentials"
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
