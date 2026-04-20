defmodule SynologyZipper.Planner do
  @moduledoc """
  Pure computation: which months should we zip *right now*?

  Ported from `internal/planner/planner.go`. All dates are handled as
  `Date` values in UTC — good enough since month boundaries are
  coarser than any plausible timezone offset.
  """

  @type month_key :: String.t()

  @doc """
  The most recent month (`"YYYY-MM"`) whose last day is at least
  `grace_days` before `today` AND fully in the past.

  Matches the loop in Go's `LatestEligibleMonth`.
  """
  @spec latest_eligible_month(Date.t(), non_neg_integer()) :: month_key
  def latest_eligible_month(%Date{} = today, grace_days)
      when is_integer(grace_days) and grace_days >= 0 do
    step(today, Date.new!(today.year, today.month, 1), grace_days)
  end

  defp step(today, month_start, grace_days) do
    last_day = month_start |> Date.add(days_in_month(month_start)) |> Date.add(-1)
    diff = Date.diff(today, last_day)

    if diff >= grace_days and Date.compare(today, last_day) == :gt do
      month_key(month_start)
    else
      prev = month_start |> Date.add(-1) |> Date.beginning_of_month()
      step(today, prev, grace_days)
    end
  end

  @doc """
  Ordered list of candidate months from `start_month` through
  `latest_eligible_month(today, grace_days)`, minus any month in
  `zipped` (MapSet or plain list of `"YYYY-MM"` strings).

  Returns `[]` when `start_month` is later than the latest eligible
  month, or when the input can't be parsed.
  """
  @spec candidate_months(month_key, Date.t(), non_neg_integer(), Enumerable.t()) :: [month_key]
  def candidate_months(start_month, %Date{} = today, grace_days, zipped)
      when is_binary(start_month) and is_integer(grace_days) and grace_days >= 0 do
    with {:ok, start_date} <- parse_month(start_month),
         latest <- latest_eligible_month(today, grace_days),
         {:ok, end_date} <- parse_month(latest) do
      if Date.compare(start_date, end_date) == :gt do
        []
      else
        zipped_set = normalise(zipped)

        start_date
        |> iterate_months(end_date)
        |> Enum.reject(&MapSet.member?(zipped_set, &1))
      end
    else
      _ -> []
    end
  end

  @doc "Parses `\"YYYY-MM\"` into the first-of-month Date."
  @spec parse_month(month_key) :: {:ok, Date.t()} | :error
  def parse_month(<<year::binary-size(4), "-", month::binary-size(2)>>) do
    with {y, ""} <- Integer.parse(year),
         {m, ""} <- Integer.parse(month),
         true <- m in 1..12,
         {:ok, date} <- Date.new(y, m, 1) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  def parse_month(_), do: :error

  # ---------------------------------------------------------------------------

  defp normalise(%MapSet{} = ms), do: ms
  defp normalise(list) when is_list(list), do: MapSet.new(list)
  defp normalise(_), do: MapSet.new()

  defp iterate_months(start, end_date) do
    start
    |> Stream.iterate(fn d -> d |> Date.add(days_in_month(d)) end)
    |> Stream.take_while(&(Date.compare(&1, end_date) != :gt))
    |> Enum.map(&month_key/1)
  end

  defp days_in_month(%Date{} = d), do: Date.days_in_month(d)

  defp month_key(%Date{year: y, month: m}),
    do: :io_lib.format("~4..0B-~2..0B", [y, m]) |> IO.iodata_to_binary()
end
