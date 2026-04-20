defmodule SynologyZipper.RetryTest do
  use ExUnit.Case, async: true

  alias SynologyZipper.Retry

  test "succeeds on the first attempt" do
    counter = :counters.new(1, [])

    assert {:ok, :hello} =
             Retry.run(
               fn ->
                 :counters.add(counter, 1, 1)
                 {:ok, :hello}
               end,
               %{attempts: 3, base: 1},
               fn _ -> true end
             )

    assert :counters.get(counter, 1) == 1
  end

  test "retries transient failures then succeeds" do
    counter = :counters.new(1, [])

    result =
      Retry.run(
        fn ->
          n = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if n < 1 do
            {:error, :transient}
          else
            {:ok, :ok}
          end
        end,
        %{attempts: 3, base: 1},
        fn _ -> true end
      )

    assert {:ok, :ok} = result
    assert :counters.get(counter, 1) == 2
  end

  test "gives up after :attempts" do
    counter = :counters.new(1, [])
    boom = :boom

    result =
      Retry.run(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, boom}
        end,
        %{attempts: 3, base: 1},
        fn _ -> true end
      )

    assert {:error, :boom} = result
    assert :counters.get(counter, 1) == 3
  end

  test "non-transient failures fail fast" do
    counter = :counters.new(1, [])

    result =
      Retry.run(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, :permanent}
        end,
        %{attempts: 5, base: 1},
        fn _ -> false end
      )

    assert {:error, :permanent} = result
    assert :counters.get(counter, 1) == 1
  end

  test "transient_io?/1 matches the known-flaky patterns" do
    assert Retry.transient_io?("resource temporarily unavailable")
    assert Retry.transient_io?("device or resource busy")
    assert Retry.transient_io?("i/o timeout")
    assert Retry.transient_io?(:eagain)
    assert Retry.transient_io?(:ebusy)

    refute Retry.transient_io?("permission denied")
    refute Retry.transient_io?("no such file or directory")
    refute Retry.transient_io?(nil)
  end
end
