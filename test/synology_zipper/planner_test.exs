defmodule SynologyZipper.PlannerTest do
  use ExUnit.Case, async: true

  alias SynologyZipper.Planner

  defp d(s), do: Date.from_iso8601!(s)

  describe "latest_eligible_month/2" do
    test "matches the Go reference table" do
      cases = [
        {"2026-04-04", 3, "2026-03"},
        {"2026-04-03", 3, "2026-03"},
        {"2026-04-02", 3, "2026-02"},
        {"2026-04-01", 0, "2026-03"},
        {"2026-03-31", 0, "2026-02"}
      ]

      for {today, grace, want} <- cases do
        got = Planner.latest_eligible_month(d(today), grace)

        assert got == want,
               "latest_eligible_month(#{today}, #{grace}) = #{got}, want #{want}"
      end
    end
  end

  describe "candidate_months/4" do
    test "simple range" do
      got = Planner.candidate_months("2026-01", d("2026-04-04"), 3, MapSet.new())
      assert got == ["2026-01", "2026-02", "2026-03"]
    end

    test "excludes months already zipped" do
      got = Planner.candidate_months("2026-01", d("2026-04-04"), 3, MapSet.new(["2026-02"]))
      assert got == ["2026-01", "2026-03"]
    end

    test "start_month after the latest eligible month returns []" do
      got = Planner.candidate_months("2026-05", d("2026-04-04"), 3, MapSet.new())
      assert got == []
    end

    test "all months zipped returns []" do
      zipped = MapSet.new(["2026-01", "2026-02", "2026-03"])
      got = Planner.candidate_months("2026-01", d("2026-04-04"), 3, zipped)
      assert got == []
    end

    test "accepts a plain list for zipped" do
      got = Planner.candidate_months("2026-01", d("2026-04-04"), 3, ["2026-02"])
      assert got == ["2026-01", "2026-03"]
    end

    test "bad start_month returns []" do
      assert Planner.candidate_months("not-a-month", d("2026-04-04"), 3, []) == []
      assert Planner.candidate_months("2026-13", d("2026-04-04"), 3, []) == []
    end
  end

  describe "parse_month/1" do
    test "accepts YYYY-MM" do
      assert {:ok, ~D[2024-01-01]} = Planner.parse_month("2024-01")
      assert {:ok, ~D[2024-12-01]} = Planner.parse_month("2024-12")
    end

    test "rejects invalid input" do
      for bad <- ["2024-13", "2024-00", "24-01", "not-a-month", "", "2024-1"] do
        assert Planner.parse_month(bad) == :error, "expected #{inspect(bad)} to error"
      end
    end
  end
end
