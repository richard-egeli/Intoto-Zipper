defmodule SynologyZipper.ZipperTest do
  use ExUnit.Case, async: true

  alias SynologyZipper.Zipper

  defp write_file!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp tmp_dir!(context) do
    base =
      System.tmp_dir!()
      |> Path.join("synology_zipper_test_#{context}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    base
  end

  describe "collect_files/2" do
    test "gathers regular files in matching date dirs and skips noise" do
      root = tmp_dir!("collect")

      write_file!(Path.join([root, "2026-03-01", "a.mp4"]), "a")
      write_file!(Path.join([root, "2026-03-15", "b.mp4"]), "b")
      write_file!(Path.join([root, "2026-03-31", "c.mp4"]), "c")

      # Out-of-month — must be excluded.
      write_file!(Path.join([root, "2026-02-28", "old.mp4"]), "old")
      write_file!(Path.join([root, "2026-04-01", "new.mp4"]), "new")

      # Skipped: dotfiles, @eaDir, symlinks.
      write_file!(Path.join([root, "2026-03-02", ".DS_Store"]), "x")
      write_file!(Path.join([root, "2026-03-02", "@eaDir", "ignore.txt"]), "x")
      write_file!(Path.join([root, "README.txt"]), "x")

      symlink_ok =
        case :file.make_symlink(
               ~c"a.mp4",
               String.to_charlist(Path.join([root, "2026-03-01", "linked.mp4"]))
             ) do
          :ok -> true
          _ -> false
        end

      assert {:ok, {files, skipped}} = Zipper.collect_files(root, "2026-03")

      got_rel = files |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert got_rel == [
               "2026-03-01/a.mp4",
               "2026-03-15/b.mp4",
               "2026-03-31/c.mp4"
             ]

      if symlink_ok do
        assert skipped > 0
      end
    end

    test "empty month returns no files, no error" do
      root = tmp_dir!("empty")
      write_file!(Path.join([root, "2026-02-15", "a.mp4"]), "a")
      assert {:ok, {[], _}} = Zipper.collect_files(root, "2026-03")
    end

    test "accepts YY-MM-DD directory names (2-digit year → 20YY)" do
      root = tmp_dir!("yyshort")

      write_file!(Path.join([root, "25-12-01", "a.mp4"]), "a")
      write_file!(Path.join([root, "25-12-15", "b.mp4"]), "b")
      # Out of the target month.
      write_file!(Path.join([root, "25-11-30", "old.mp4"]), "old")

      assert {:ok, {files, _}} = Zipper.collect_files(root, "2025-12")

      got_rel = files |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert got_rel == ["25-12-01/a.mp4", "25-12-15/b.mp4"]
    end

    test "accepts mixed YY-MM-DD and YYYY-MM-DD in the same root" do
      root = tmp_dir!("mixed")

      write_file!(Path.join([root, "25-12-01", "a.mp4"]), "a")
      write_file!(Path.join([root, "2025-12-15", "b.mp4"]), "b")

      assert {:ok, {files, _}} = Zipper.collect_files(root, "2025-12")

      got_rel = files |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert got_rel == ["2025-12-15/b.mp4", "25-12-01/a.mp4"]
    end
  end

  describe "write_zip/2" do
    test "happy path produces a uncompressed zip and cleans the tmp" do
      root = tmp_dir!("happy")
      write_file!(Path.join([root, "2026-03-01", "a.mp4"]), "aaa")
      write_file!(Path.join([root, "2026-03-15", "b.mp4"]), "bbbb")

      assert {:ok, result} = Zipper.write_zip(root, "2026-03")
      assert result.path == Path.join(root, "2026-03.zip")
      assert result.file_count == 2
      assert result.bytes > 0
      refute File.exists?(Path.join(root, ".2026-03.zip.tmp"))

      # Open the zip and inspect contents.
      {:ok, entries} = :zip.list_dir(String.to_charlist(result.path))

      file_entries =
        Enum.filter(entries, fn
          {:zip_file, _, _, _, _, _} -> true
          _ -> false
        end)

      names =
        Enum.map(file_entries, fn {:zip_file, n, _, _, _, _} -> to_string(n) end) |> Enum.sort()

      assert names == ["2026-03-01/a.mp4", "2026-03-15/b.mp4"]

      # Verify bodies + "stored" (uncompressed) method: with :uncompressed
      # option the compressed size equals the original size.
      for {:zip_file, name, info, _, _, _} <- file_entries do
        assert :file_info == elem(info, 0)
        {:file_info, size, :regular, _, _, _, _, _, _, _, _, _, _, _} = info
        expected = if to_string(name) =~ "a.mp4", do: 3, else: 4
        assert size == expected
      end

      # Extract and check bodies.
      {:ok, _} =
        :zip.extract(
          String.to_charlist(result.path),
          [{:cwd, String.to_charlist(Path.join(root, "extracted"))}]
        )

      assert File.read!(Path.join([root, "extracted", "2026-03-01", "a.mp4"])) == "aaa"
      assert File.read!(Path.join([root, "extracted", "2026-03-15", "b.mp4"])) == "bbbb"
    end

    test "empty month returns no zip on disk and nil path" do
      root = tmp_dir!("nozip")
      assert {:ok, result} = Zipper.write_zip(root, "2026-03")
      assert result.path == nil
      assert result.file_count == 0
      refute File.exists?(Path.join(root, "2026-03.zip"))
    end

    test "atomic: if rename target is a directory, we error and clean up tmp" do
      root = tmp_dir!("atomic")
      write_file!(Path.join([root, "2026-03-01", "a.mp4"]), "aaa")

      # Pre-create a *directory* at the final path so File.rename fails.
      File.mkdir_p!(Path.join(root, "2026-03.zip"))

      assert {:error, _} = Zipper.write_zip(root, "2026-03")
      refute File.exists?(Path.join(root, ".2026-03.zip.tmp"))
    end
  end
end
