defmodule SynologyZipperWeb.RunsLive do
  @moduledoc """
  /runs — recent run history (default 50). Mirrors
  `internal/web/templates/runs.html`.

  PubSub: subscribes to the `"runs"` topic and refreshes on every
  `{:run_changed, _}` event (and incidentally repaints when
  `{:run_start, _}` / `{:run_end, _, _}` arrive via the shared hook).
  """

  use SynologyZipperWeb, :live_view

  on_mount {SynologyZipperWeb.Live.Hooks, :runs}

  alias SynologyZipper.State
  alias SynologyZipperWeb.Live.Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      State.subscribe_runs()
    end

    {:ok,
     socket
     |> assign(:page_title, "Runs")
     |> assign(:runs, State.list_runs(50))}
  end

  @impl true
  def handle_info({:run_changed, _id}, socket) do
    {:noreply, assign(socket, :runs, State.list_runs(50))}
  end

  # :run_start / :run_end are handled by the shared hook for the
  # status pill; they don't add a new row so no refresh needed.
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <h2 class="mb-5 text-[22px] font-semibold tracking-tight text-gray-800">Runs</h2>

    <%= if @runs == [] do %>
      <div class="rounded-md border border-dashed border-gray-300 bg-gray-50 px-4 py-10 text-center text-gray-400">
        No runs recorded yet.
      </div>
    <% else %>
      <div class="overflow-hidden rounded-md border border-gray-200 bg-white shadow-sm">
        <table class="w-full border-separate border-spacing-0 text-left text-[13.5px]">
          <thead>
            <tr class="bg-gray-50 text-[11.5px] uppercase tracking-wider text-gray-500">
              <th class="border-b border-gray-200 px-4 py-2.5 text-right font-medium">ID</th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Started</th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Finished</th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Status</th>
              <th class="border-b border-gray-200 px-4 py-2.5 text-right font-medium">Zipped</th>
              <th class="border-b border-gray-200 px-4 py-2.5 text-right font-medium">Failed</th>
              <th class="border-b border-gray-200 px-4 py-2.5 font-medium">Notes</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @runs} class="hover:bg-gray-50">
              <td class="border-b border-gray-100 px-4 py-2.5 text-right font-mono text-[12.5px] text-gray-500 tabular-nums">
                {run.id}
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 font-mono text-[12.5px] text-gray-500">
                {Helpers.fmt_dt_sec(run.started_at)}
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 font-mono text-[12.5px] text-gray-500">
                <%= if run.finished_at do %>
                  {Helpers.fmt_dt_sec(run.finished_at)}
                <% else %>
                  <span class="text-gray-400">—</span>
                <% end %>
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5">
                <%= if run.exit_status in [nil, ""] do %>
                  <span class="text-gray-400">—</span>
                <% else %>
                  <.status_badge status={run.exit_status} />
                <% end %>
              </td>
              <td class="border-b border-gray-100 px-4 py-2.5 text-right tabular-nums">
                {run.months_zipped}
              </td>
              <td class="border-b border-gray-100 px-4 py-2.5 text-right tabular-nums">
                {run.months_failed}
              </td>
              <td class="border-b border-gray-100 px-4 py-2.5 text-[12.5px] text-gray-500">
                {run.notes}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  attr :status, :string, required: true

  defp status_badge(%{status: status} = assigns) do
    {bg, text, border} =
      case status do
        s when s in ["zipped", "ok"] -> {"bg-emerald-50", "text-emerald-700", "border-emerald-200"}
        s when s in ["failed", "error"] -> {"bg-red-50", "text-red-700", "border-red-200"}
        "partial" -> {"bg-amber-50", "text-amber-700", "border-amber-200"}
        _ -> {"bg-gray-50", "text-gray-500", "border-gray-200"}
      end

    assigns = assign(assigns, bg: bg, text: text, border: border)

    ~H"""
    <span class={[
      "inline-block rounded-full border px-2 py-0.5 text-[11.5px] font-medium",
      @bg,
      @text,
      @border
    ]}>
      {@status}
    </span>
    """
  end
end
