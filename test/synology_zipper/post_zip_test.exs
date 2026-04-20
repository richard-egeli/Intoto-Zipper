defmodule SynologyZipper.PostZipTest do
  use ExUnit.Case, async: true

  alias SynologyZipper.PostZip

  def write_file!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  def tmp_dir!(context) do
    base =
      System.tmp_dir!()
      |> Path.join("synology_zipper_postzip_#{context}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(base) end)
    base
  end

  describe ":keep" do
    test "leaves everything in place" do
      root = tmp_dir!("keep")
      write_file!(Path.join([root, "2026-03-01", "a.mp4"]), "a")

      assert :ok =
               PostZip.execute(%{
                 action: :keep,
                 source_name: "cam-a",
                 source_path: root,
                 month: "2026-03"
               })

      assert File.exists?(Path.join([root, "2026-03-01", "a.mp4"]))
    end
  end

  describe ":move" do
    test "relocates date dirs into <move_to>/<source_name>/" do
      root = tmp_dir!("move")
      archive = tmp_dir!("move_dest")
      write_file!(Path.join([root, "2026-03-01", "a.mp4"]), "a")

      assert :ok =
               PostZip.execute(%{
                 action: :move,
                 source_name: "cam-a",
                 source_path: root,
                 month: "2026-03",
                 move_to: archive
               })

      refute File.exists?(Path.join([root, "2026-03-01"]))
      moved = Path.join([archive, "cam-a", "2026-03-01", "a.mp4"])
      assert File.read!(moved) == "a"
    end

    test "missing move_to yields an error and leaves source intact" do
      root = tmp_dir!("move_bad")
      write_file!(Path.join([root, "2026-03-01", "a.mp4"]), "a")

      assert {:error, _} =
               PostZip.execute(%{
                 action: :move,
                 source_name: "cam-a",
                 source_path: root,
                 month: "2026-03"
               })

      assert File.exists?(Path.join([root, "2026-03-01", "a.mp4"]))
    end
  end

  # This is the critical invariant port of
  # TestExecuteNeverRemovesSourceFilesExceptMove from the Go suite.
  describe "never removes source files except move" do
    @matrix [
      {"empty action", nil, false, false},
      {"empty string", "", false, false},
      {"keep atom", :keep, false, false},
      {"keep string", "keep", false, false},
      {"legacy delete lowercase", "delete", false, false},
      {"legacy delete uppercase", "DELETE", false, false},
      {"legacy delete mixed case", "Delete", false, false},
      {"legacy rm alias", "rm", false, false},
      {"legacy remove alias", "remove", false, false},
      {"legacy purge alias", "purge", false, false},
      {"garbage string", "not-a-real-action", false, false},
      {"whitespace", "  ", false, false},
      {"sql injection lookalike", "delete; drop table sources", false, false},
      {"move atom with move_to", :move, true, true}
    ]

    for {label, action, with_move_to, target_month_gone} <- @matrix do
      test "action #{inspect(action)} (#{label})" do
        root = unquote(__MODULE__).tmp_dir!("matrix")
        archive = unquote(__MODULE__).tmp_dir!("matrix_dest")

        # Target-month files
        unquote(__MODULE__).write_file!(Path.join([root, "2026-03-01", "a.mp4"]), "a")
        unquote(__MODULE__).write_file!(Path.join([root, "2026-03-15", "b.mp4"]), "b")
        unquote(__MODULE__).write_file!(Path.join([root, "2026-03-31", "c.mp4"]), "c")
        # Unrelated month — must always survive
        unquote(__MODULE__).write_file!(Path.join([root, "2026-04-01", "d.mp4"]), "d")
        # Zip artifact — must also survive
        unquote(__MODULE__).write_file!(Path.join([root, "2026-03.zip"]), "zip")

        move_to = if unquote(with_move_to), do: archive, else: nil

        params = %{
          action: unquote(Macro.escape(action)),
          source_name: "cam-a",
          source_path: root,
          month: "2026-03"
        }

        params = if move_to, do: Map.put(params, :move_to, move_to), else: params

        # Ignore return — even an error must not remove anything beyond a
        # legitimate :move.
        _ = PostZip.execute(params)

        # Unrelated month MUST survive.
        assert File.exists?(Path.join([root, "2026-04-01", "d.mp4"])),
               "action #{inspect(unquote(Macro.escape(action)))} touched unrelated month"

        # Zip artifact MUST survive.
        assert File.exists?(Path.join(root, "2026-03.zip")),
               "action #{inspect(unquote(Macro.escape(action)))} removed zip artifact"

        # Target month files: only absent after a legitimate :move.
        for rel <- ["2026-03-01/a.mp4", "2026-03-15/b.mp4", "2026-03-31/c.mp4"] do
          path = Path.join(root, rel)

          if unquote(target_month_gone) do
            refute File.exists?(path),
                   "legitimate move should have relocated #{rel}"

            moved = Path.join([archive, "cam-a", rel])

            assert File.exists?(moved),
                   "legitimate move dropped #{rel} — expected at #{moved}"
          else
            assert File.exists?(path),
                   "action #{inspect(unquote(Macro.escape(action)))} MUST preserve #{rel}"
          end
        end
      end
    end
  end

  # Structural guard: no File.rm* call anywhere in post_zip.ex.
  test "post_zip.ex contains no destructive file calls" do
    body = File.read!(Path.expand("../../lib/synology_zipper/post_zip.ex", __DIR__))

    for forbidden <- ["File.rm(", "File.rm!", "File.rm_rf", ":file.delete"] do
      refute String.contains?(body, forbidden),
             "post_zip.ex must not contain #{inspect(forbidden)} — this tool never removes from source"
    end
  end
end
