defmodule SynologyZipper.PostZip do
  @moduledoc """
  Post-zip side-effects on the source folder.

  **Non-negotiable invariant:** this module NEVER removes anything
  from the source. Only `:move` is destructive, and even then the
  files end up at `<move_to>/<source_name>/<date_dir>/...` rather
  than being unlinked outright.

  Matches the Go `postzip` package — legacy `"delete"` is kept alive
  as a deliberate no-op so that a hand-edited DB row can't suddenly
  delete a user's footage.
  """

  @date_dir_re ~r/^(\d{4})-(\d{2})-(\d{2})$/

  @type params :: %{
          required(:action) => atom() | String.t(),
          required(:source_name) => String.t(),
          required(:source_path) => String.t(),
          required(:month) => String.t(),
          optional(:move_to) => String.t() | nil
        }

  @doc """
  Run the configured post-zip action.

  - `:keep` / `"keep"` / missing / any unknown value: no-op (ok).
  - `:move` / `"move"`: relocate all date-folders for `month` from
    `source_path` to `<move_to>/<source_name>/`. Fails if `move_to` is
    blank.

  Every other value — including legacy `"delete"` / `"DELETE"` / `"rm"`
  / `"purge"` / `"garbage"` / whitespace / SQL-injection-looking
  strings — is explicitly a no-op. `source_path` stays untouched.
  """
  @spec execute(params) :: :ok | {:error, term()}
  def execute(%{action: action} = p) do
    case normalise(action) do
      :keep ->
        :ok

      :move ->
        move_month(p)

      :unknown ->
        # Legacy / typo / attacker-crafted values — never destructive.
        :ok
    end
  end

  # ---------------------------------------------------------------------------

  defp normalise(:keep), do: :keep
  defp normalise(:move), do: :move
  defp normalise(nil), do: :keep
  defp normalise(""), do: :keep
  defp normalise("keep"), do: :keep
  defp normalise("move"), do: :move
  # Everything else (including Go's removed `"delete"` action, `"DELETE"`,
  # `"rm"`, whitespace, weird injection attempts, …) maps to :unknown →
  # no-op. This is intentional; see the module doc.
  defp normalise(_), do: :unknown

  defp move_month(%{move_to: move_to}) when move_to in [nil, ""] do
    {:error, :move_to_required}
  end

  defp move_month(%{
         source_path: source_path,
         month: month,
         source_name: source_name,
         move_to: move_to
       }) do
    dest = Path.join(move_to, source_name)

    with :ok <- File.mkdir_p(dest),
         :ok <- for_each_month_date_dir(source_path, month, &rename_into(&1, &2, dest)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp move_month(_), do: {:error, :move_to_required}

  defp rename_into(dir_name, full_path, dest) do
    target = Path.join(dest, dir_name)

    case File.rename(full_path, target) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename, full_path, target, reason}}
    end
  end

  defp for_each_month_date_dir(source_path, month, fun) do
    case File.ls(source_path) do
      {:error, reason} ->
        {:error, {:read_source, source_path, reason}}

      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce_while(:ok, fn name, _acc ->
          full = Path.join(source_path, name)

          if File.dir?(full) and matches_month?(name, month) do
            case fun.(name, full) do
              :ok -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end
          else
            {:cont, :ok}
          end
        end)
    end
  end

  defp matches_month?(dir_name, month) do
    case Regex.run(@date_dir_re, dir_name) do
      [_, y, m, _] -> "#{y}-#{m}" == month
      _ -> false
    end
  end
end
