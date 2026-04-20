defmodule SynologyZipperWeb.Live.Helpers do
  @moduledoc """
  Small view helpers shared across the three LiveViews. Ports the
  formatting primitives from `internal/web/web.go` (`humanBytes`,
  `truncate`) and the `bannerWarning` conditional.
  """

  alias SynologyZipper.{State, Uploader}

  @doc """
  Returns the credentials-missing banner message (or `nil`). Mirrors
  `web.go:bannerWarning` exactly:

    * Nothing when the uploader is not disabled.
    * Nothing when the uploader is disabled but no source has
      `auto_upload=true` (feature not in use, banner would be noise).
    * Otherwise, a human-readable sentence naming the missing path.
  """
  def banner_warning do
    disabled? =
      try do
        Uploader.disabled?()
      catch
        :exit, _ -> false
      end

    with true <- disabled?,
         true <- State.any_auto_upload?() do
      case System.get_env("GOOGLE_APPLICATION_CREDENTIALS") do
        nil ->
          "Google Drive credentials not found at $GOOGLE_APPLICATION_CREDENTIALS. Uploads are disabled."

        "" ->
          "Google Drive credentials not found at $GOOGLE_APPLICATION_CREDENTIALS. Uploads are disabled."

        path ->
          "Google Drive credentials not found at #{path}. Uploads are disabled."
      end
    else
      _ -> nil
    end
  end

  @doc """
  True while the scheduler is currently executing a tick. Returns
  false if the scheduler process isn't running (tests that boot a
  partial tree).
  """
  def scheduler_running? do
    try do
      SynologyZipper.Scheduler.running?()
    catch
      :exit, _ -> false
    end
  end

  @doc "Formats bytes with 1-decimal binary units; `—` for zero/negative."
  def human_bytes(n) when is_integer(n) and n <= 0, do: "—"

  def human_bytes(n) when is_integer(n) and n < 1024, do: "#{n} B"

  def human_bytes(n) when is_integer(n) do
    # Matches Go's humanBytes: 1024-divide down, label K/M/G/T/P/E.
    units = [?K, ?M, ?G, ?T, ?P, ?E]
    reduce_bytes(n / 1024, units)
  end

  def human_bytes(_), do: "—"

  defp reduce_bytes(value, [unit]) do
    :io_lib.format("~.1f ~cB", [value, unit]) |> IO.iodata_to_binary()
  end

  defp reduce_bytes(value, [_unit | rest]) when value >= 1024 do
    reduce_bytes(value / 1024, rest)
  end

  defp reduce_bytes(value, [unit | _]) do
    :io_lib.format("~.1f ~cB", [value, unit]) |> IO.iodata_to_binary()
  end

  @doc "Formats a `DateTime` as `YYYY-MM-DD HH:MM` (nil -> nil)."
  def fmt_dt(nil), do: nil

  def fmt_dt(%DateTime{} = dt) do
    "#{pad(dt.year, 4)}-#{pad(dt.month, 2)}-#{pad(dt.day, 2)} " <>
      "#{pad(dt.hour, 2)}:#{pad(dt.minute, 2)}"
  end

  @doc "Formats a `DateTime` with seconds, used on /runs."
  def fmt_dt_sec(nil), do: nil

  def fmt_dt_sec(%DateTime{} = dt) do
    "#{pad(dt.year, 4)}-#{pad(dt.month, 2)}-#{pad(dt.day, 2)} " <>
      "#{pad(dt.hour, 2)}:#{pad(dt.minute, 2)}:#{pad(dt.second, 2)}"
  end

  @doc "Truncates to `n` chars with an ellipsis when longer (matches Go's `truncate`)."
  def truncate(s, n) when is_binary(s) and is_integer(n) and n > 0 do
    if byte_size(s) <= n do
      s
    else
      binary_part(s, 0, n) <> "…"
    end
  end

  def truncate(s, _), do: s

  defp pad(i, w), do: i |> Integer.to_string() |> String.pad_leading(w, "0")
end
