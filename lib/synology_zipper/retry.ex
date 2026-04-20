defmodule SynologyZipper.Retry do
  @moduledoc """
  Straight port of `internal/retry/retry.go` — 30 lines of exponential
  backoff with a caller-supplied transient predicate.

  Explicitly not hex'd out (`:retry` is way more library than we need).
  """

  @type options :: %{
          optional(:attempts) => pos_integer(),
          optional(:base) => pos_integer()
        }

  @default_attempts 3
  @default_base 1_000

  @doc """
  Calls `fun.()` up to `attempts` times. Returns `{:ok, value}` on
  success. On failure:

    * if `transient?.(reason)` is truthy **and** there's an attempt left,
      sleep `base_ms * 2^(attempt-1)` and try again;
    * otherwise return `{:error, reason}`.

  The callee must return `{:ok, value}` or `{:error, reason}`.
  """
  @spec run((-> {:ok, any()} | {:error, any()}), options, (any() -> boolean())) ::
          {:ok, any()} | {:error, any()}
  def run(fun, opts \\ %{}, transient?) when is_function(fun, 0) and is_function(transient?, 1) do
    attempts = max(Map.get(opts, :attempts, @default_attempts), 1)
    base = Map.get(opts, :base, @default_base)
    do_run(fun, transient?, attempts, 1, base)
  end

  defp do_run(fun, transient?, attempts, i, delay) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      :ok ->
        {:ok, nil}

      {:error, reason} = err ->
        cond do
          i >= attempts ->
            err

          transient?.(reason) ->
            Process.sleep(delay)
            do_run(fun, transient?, attempts, i + 1, delay * 2)

          true ->
            err
        end
    end
  end

  @doc """
  Transient-I/O heuristic used by the zipper when opening source files
  on a flaky NAS. Ports `retry.IsTransientIOError` — string-sniffs the
  error message for known-flaky patterns.
  """
  @spec transient_io?(any()) :: boolean()
  def transient_io?(nil), do: false

  def transient_io?(reason) do
    msg = error_to_string(reason)

    String.contains?(msg, "resource temporarily unavailable") or
      String.contains?(msg, "device or resource busy") or
      String.contains?(msg, "connection reset") or
      String.contains?(msg, "i/o timeout") or
      String.contains?(msg, "temporary failure") or
      reason in [:eagain, :ebusy, :etimedout]
  end

  defp error_to_string(s) when is_binary(s), do: s
  defp error_to_string(a) when is_atom(a), do: :erlang.atom_to_binary(a, :utf8)
  defp error_to_string(other), do: inspect(other)
end
