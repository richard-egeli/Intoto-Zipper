defmodule SynologyZipper.StubUploader do
  @moduledoc """
  Test-only uploader that satisfies the Runner seam (`upload/1` +
  `disabled?/0` + `disabled_reason/0`). Backed by a named Agent so
  tests can programme responses keyed by `{source_name, month}`.
  """
  use Agent

  alias SynologyZipper.Uploader.{Job, Result}

  @type response :: {:ok, Result.t()} | {:error, term()} | {:crash, term()}

  def start_link(opts \\ []) do
    name = Keyword.fetch!(opts, :name)

    initial = %{
      disabled: Keyword.get(opts, :disabled, false),
      disabled_reason: Keyword.get(opts, :disabled_reason, "stub disabled"),
      plan: Keyword.get(opts, :plan, %{}),
      default: Keyword.get(opts, :default, {:error, :no_plan}),
      calls: []
    }

    Agent.start_link(fn -> initial end, name: name)
  end

  def upload(name \\ __MODULE__, %Job{} = job) do
    response =
      Agent.get_and_update(name, fn state ->
        key = {job.source_name, job.month}
        response = Map.get(state.plan, key, state.default)
        {response, %{state | calls: [key | state.calls]}}
      end)

    case response do
      # Exit the caller — simulates a crash inside the upload path (e.g.
      # a `GenServer.call` timeout, which is what actually happened in
      # prod on 2026-04-21). `exit/1` kills the calling process, which
      # in the runner flow is the async upload Task.
      {:crash, reason} -> exit(reason)
      other -> other
    end
  end

  def disabled?(name \\ __MODULE__), do: Agent.get(name, & &1.disabled)
  def disabled_reason(name \\ __MODULE__), do: Agent.get(name, & &1.disabled_reason)
  def calls(name \\ __MODULE__), do: Agent.get(name, fn s -> Enum.reverse(s.calls) end)
end
