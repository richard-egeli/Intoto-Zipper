defmodule SynologyZipper.Zipper do
  @moduledoc """
  Build `<source_path>/YYYY-MM.zip` for one month.

  Ports `internal/zipper/zipper.go`:

    * Only date-folders of the form `YYYY-MM-DD` that fall in the
      requested month are considered.
    * Regular files only; symlinks, dotfiles, and `@eaDir/` children
      are skipped (and counted in `:skipped`).
    * Writes to `.<month>.zip.tmp` then atomically renames to
      `<month>.zip` on success. On any failure, the temp file is
      removed so a future retry starts clean.
    * Entries are stored *uncompressed* — the source is already H.264
      video; recompression just burns CPU for a fraction of a percent.
  """

  # `YYYY-MM-DD` or `YY-MM-DD` (2-digit year assumed to be 20YY).
  # Synology's timelapse / camera folders often use the 2-digit form.
  @date_dir_re ~r/^(\d{2}|\d{4})-(\d{2})-(\d{2})$/

  @type result :: %{
          path: String.t() | nil,
          bytes: non_neg_integer(),
          file_count: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @doc """
  Archive `source_path`'s files for `month` into `<source_path>/<month>.zip`.
  Empty months return `{:ok, %{path: nil, ...}}` without creating a file.
  """
  @spec write_zip(String.t(), String.t()) :: {:ok, result} | {:error, term()}
  def write_zip(source_path, month) when is_binary(source_path) and is_binary(month) do
    with {:ok, {files, skipped}} <- collect_files(source_path, month) do
      case files do
        [] ->
          {:ok, %{path: nil, bytes: 0, file_count: 0, skipped: skipped}}

        _ ->
          write_nonempty_zip(source_path, month, files, skipped)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Collect
  # ---------------------------------------------------------------------------

  @doc false
  def collect_files(source_path, month) do
    case File.ls(source_path) do
      {:error, reason} ->
        {:error, {:read_source, source_path, reason}}

      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce_while({:ok, {[], 0}}, fn name, {:ok, {files, skipped}} ->
          full = Path.join(source_path, name)

          with true <- File.dir?(full),
               true <- matches_month?(name, month) do
            case walk_date_dir(full, source_path) do
              {:ok, more_files, more_skipped} ->
                {:cont, {:ok, {files ++ more_files, skipped + more_skipped}}}

              {:error, _} = err ->
                {:halt, err}
            end
          else
            _ -> {:cont, {:ok, {files, skipped}}}
          end
        end)
        |> case do
          {:ok, {files, skipped}} ->
            sorted = Enum.sort_by(files, &elem(&1, 0))
            {:ok, {sorted, skipped}}

          {:error, _} = err ->
            err
        end
    end
  end

  # Walks one `YYYY-MM-DD/` directory, skipping @eaDir subtrees, dotfiles,
  # symlinks, and anything that isn't a regular file. Returns a list of
  # `{rel_path_slash, abs_path}` pairs plus a count of skipped entries.
  defp walk_date_dir(date_dir, source_root) do
    walk(date_dir, source_root, [], 0)
  end

  defp walk(path, source_root, files, skipped) do
    case File.ls(path) do
      {:error, reason} ->
        {:error, {:read_dir, path, reason}}

      {:ok, entries} ->
        Enum.reduce_while(entries, {:ok, {files, skipped}}, fn name, {:ok, {fs, sk}} ->
          full = Path.join(path, name)

          case File.lstat(full) do
            {:error, reason} ->
              {:halt, {:error, {:lstat, full, reason}}}

            {:ok, %File.Stat{type: :directory}} ->
              if name == "@eaDir" do
                {:cont, {:ok, {fs, sk}}}
              else
                case walk(full, source_root, fs, sk) do
                  {:ok, {new_fs, new_sk}} -> {:cont, {:ok, {new_fs, new_sk}}}
                  {:error, _} = err -> {:halt, err}
                end
              end

            {:ok, %File.Stat{type: :symlink}} ->
              {:cont, {:ok, {fs, sk + 1}}}

            {:ok, %File.Stat{type: :regular}} ->
              if String.starts_with?(name, ".") do
                {:cont, {:ok, {fs, sk + 1}}}
              else
                rel = relative_slash(full, source_root)
                {:cont, {:ok, {[{rel, full} | fs], sk}}}
              end

            {:ok, _} ->
              {:cont, {:ok, {fs, sk + 1}}}
          end
        end)
        |> case do
          {:ok, {fs, sk}} -> {:ok, fs, sk}
          {:error, _} = err -> err
        end
    end
  end

  defp relative_slash(full, root) do
    abs_full = Path.expand(full)
    abs_root = Path.expand(root)

    abs_full
    |> Path.relative_to(abs_root)
    |> Path.split()
    |> Enum.join("/")
  end

  defp matches_month?(dir_name, month) do
    case Regex.run(@date_dir_re, dir_name) do
      [_, y, m, _] -> "#{expand_year(y)}-#{m}" == month
      _ -> false
    end
  end

  defp expand_year(y) when byte_size(y) == 2, do: "20" <> y
  defp expand_year(y), do: y

  # ---------------------------------------------------------------------------
  # Orphan tmp cleanup
  # ---------------------------------------------------------------------------

  # Matches the temp pattern written by `write_nonempty_zip/4`:
  # `.<YYYY-MM>.zip.tmp`. Tight enough to avoid nuking something
  # unrelated a user might have dropped in the source dir.
  @orphan_tmp_re ~r/^\.\d{4}-\d{2}\.zip\.tmp$/

  @doc """
  Deletes any orphan `.<YYYY-MM>.zip.tmp` files under the given source
  paths. Called from `Scheduler.init/1` on boot so a BEAM crash mid-zip
  doesn't leave partial temp files to accumulate across restarts.

  Returns `{removed, errors}` — counts, for logging. Missing or
  unreadable paths are ignored (a source may point at a mounted volume
  that isn't available yet at boot; the next zip attempt will surface
  the real error via `collect_files/2`).
  """
  @spec sweep_orphan_tmp_zips([String.t()]) :: {non_neg_integer(), non_neg_integer()}
  def sweep_orphan_tmp_zips(paths) when is_list(paths) do
    Enum.reduce(paths, {0, 0}, fn path, {removed, errors} ->
      case File.ls(path) do
        {:ok, entries} ->
          Enum.reduce(entries, {removed, errors}, fn name, {r, e} ->
            if Regex.match?(@orphan_tmp_re, name) do
              case File.rm(Path.join(path, name)) do
                :ok -> {r + 1, e}
                {:error, _} -> {r, e + 1}
              end
            else
              {r, e}
            end
          end)

        {:error, _} ->
          {removed, errors}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Write
  # ---------------------------------------------------------------------------

  defp write_nonempty_zip(source_path, month, files, skipped) do
    tmp = Path.join(source_path, ".#{month}.zip.tmp")
    final = Path.join(source_path, "#{month}.zip")

    _ = File.rm(tmp)

    # `:zip.create/3` expects filename charlists — each resolved relative
    # to the :cwd option. We hand it the relative paths we collected and
    # let the NIF stream the underlying files itself.
    specs = Enum.map(files, fn {rel, _abs} -> String.to_charlist(rel) end)

    # `{:compress, []}` means "compress files matching no extensions" →
    # store-only. The source material is already compressed video, so any
    # additional compression would be CPU for a fraction of a percent.
    options = [
      {:cwd, String.to_charlist(source_path)},
      {:compress, []}
    ]

    case :zip.create(String.to_charlist(tmp), specs, options) do
      {:ok, _} ->
        finalize(tmp, final, skipped, length(files))

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:zip_create, reason}}
    end
  rescue
    e ->
      _ = File.rm(Path.join(source_path, ".#{month}.zip.tmp"))
      {:error, {:zip_create, e}}
  end

  defp finalize(tmp, final, skipped, file_count) do
    case File.rename(tmp, final) do
      :ok ->
        case File.stat(final) do
          {:ok, %File.Stat{size: size}} ->
            {:ok, %{path: final, bytes: size, file_count: file_count, skipped: skipped}}

          {:error, reason} ->
            {:error, {:stat_final, final, reason}}
        end

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:atomic_rename, tmp, final, reason}}
    end
  end
end
