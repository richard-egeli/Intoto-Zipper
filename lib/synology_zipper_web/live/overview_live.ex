defmodule SynologyZipperWeb.OverviewLive do
  @moduledoc """
  Landing page — source table (with derived upload stats) + the
  most recent 10 runs. Mirrors `internal/web/templates/dashboard.html`.

  PubSub: subscribes to the `"sources"` and `"runs"` topics so the
  table refreshes whenever the scheduler zips / uploads / finishes.
  Individual month updates also flip the derived stats on this page
  so the LiveView also subscribes per-source.
  """

  use SynologyZipperWeb, :live_view

  on_mount {SynologyZipperWeb.Live.Hooks, :overview}

  alias SynologyZipper.State
  alias SynologyZipperWeb.Live.Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      State.subscribe_sources()
      Phoenix.PubSub.subscribe(SynologyZipper.PubSub, "runs")

      # Per-source month updates also influence the overview (last-zipped,
      # uploaded-count). Subscribe once per source at mount and re-subscribe
      # when the set changes.
      Enum.each(State.list_sources(), fn s -> State.subscribe_source(s.name) end)
    end

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> refresh()}
  end

  @impl true
  def handle_info({:source_changed, _name}, socket) do
    {:noreply, refresh_and_resubscribe(socket)}
  end

  def handle_info({:source_deleted, _name}, socket) do
    {:noreply, refresh_and_resubscribe(socket)}
  end

  def handle_info({:month_changed, _source, _month}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info({:month_deleted, _source, _month}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info({:run_changed, _id}, socket) do
    {:noreply, assign(socket, :runs, State.list_runs(10))}
  end

  # {:run_start, _}, {:run_end, _, _} are handled by the shared hook.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    socket
    |> assign(:sources, State.list_sources_with_stats())
    |> assign(:runs, State.list_runs(10))
  end

  defp refresh_and_resubscribe(socket) do
    if connected?(socket) do
      Enum.each(State.list_sources(), fn s -> State.subscribe_source(s.name) end)
    end

    refresh(socket)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mb-5 flex items-center justify-between">
      <h2 class="text-[22px] font-semibold tracking-tight text-gray-800">Overview</h2>
      <.link
        navigate={~p"/sources/new"}
        class="rounded-md border border-blue-600 bg-blue-600 px-3 py-1.5 text-[13px] font-medium text-white shadow-sm hover:bg-blue-700"
      >
        + Add source
      </.link>
    </div>

    <div class="mb-5 rounded-md border border-gray-200 bg-white p-6 shadow-sm">
      <div class="mb-4 flex items-center justify-between">
        <h3 class="text-[14px] font-semibold uppercase tracking-wider text-gray-500">Sources</h3>
      </div>

      <%= if @sources == [] do %>
        <div class="rounded-md border border-dashed border-gray-300 bg-gray-50 px-4 py-10 text-center text-gray-400">
          <p>No sources configured yet.</p>
          <p class="mt-2"><.link navigate={~p"/sources/new"} class="text-blue-600 hover:underline">Add your first source →</.link></p>
        </div>
      <% else %>
        <div class="-mx-6 overflow-x-auto px-6">
        <table class="w-full min-w-[860px] border-separate border-spacing-0 text-left text-[13.5px]">
          <thead>
            <tr class="bg-gray-50 text-[11.5px] uppercase tracking-wider text-gray-500">
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Name</th>
              <th class="border-b border-gray-200 px-4 py-2.5 font-medium">Path</th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Start</th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 text-right font-medium">
                Grace
              </th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">
                Post-zip
              </th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">
                Auto-upload
              </th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">
                Last zipped
              </th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">
                Last status
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={src <- @sources}
              id={"source-row-#{src.name}"}
              data-name={src.name}
              phx-click={JS.navigate(~p"/sources/#{src.name}")}
              class="cursor-pointer hover:bg-gray-50"
            >
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5">
                <.link navigate={~p"/sources/#{src.name}"} class="font-semibold text-gray-800 hover:underline">
                  {src.name}
                </.link>
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 font-mono text-[12.5px] text-gray-500">
                {src.path}
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 font-mono text-[12.5px] text-gray-500">
                {src.start_month}
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 text-right tabular-nums">
                {src.grace_days}d
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 font-mono text-[12px]">
                {src.post_zip}
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5">
                <.upload_flag source={src} />
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 font-mono text-[12.5px] text-gray-500">
                <%= if src.last_zipped_month == "" do %>
                  <span class="text-gray-400">—</span>
                <% else %>
                  {src.last_zipped_month}
                <% end %>
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5">
                <%= if src.last_run_status == "" do %>
                  <span class="text-gray-400">—</span>
                <% else %>
                  <.status_badge status={src.last_run_status} />
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
        </div>
      <% end %>
    </div>

    <div class="mb-5 rounded-md border border-gray-200 bg-white p-6 shadow-sm">
      <div class="mb-4 flex items-center justify-between">
        <h3 class="text-[14px] font-semibold uppercase tracking-wider text-gray-500">Recent runs</h3>
        <.link :if={@runs != []} navigate={~p"/runs"} class="text-[12.5px] text-gray-400 hover:underline">
          View all →
        </.link>
      </div>

      <%= if @runs == [] do %>
        <div class="rounded-md border border-dashed border-gray-300 bg-gray-50 px-4 py-10 text-center text-gray-400">
          No runs recorded yet.
        </div>
      <% else %>
        <div class="-mx-6 overflow-x-auto px-6">
        <table class="w-full min-w-[520px] border-separate border-spacing-0 text-left text-[13.5px]">
          <thead>
            <tr class="bg-gray-50 text-[11.5px] uppercase tracking-wider text-gray-500">
              <th class="border-b border-gray-200 px-4 py-2.5 text-right font-medium">ID</th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Started</th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Status</th>
              <th class="border-b border-gray-200 px-4 py-2.5 text-right font-medium">Zipped</th>
              <th class="border-b border-gray-200 px-4 py-2.5 text-right font-medium">Failed</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @runs} class="hover:bg-gray-50">
              <td class="border-b border-gray-100 px-4 py-2.5 text-right font-mono text-[12.5px] text-gray-500 tabular-nums">
                {run.id}
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 font-mono text-[12.5px] text-gray-500">
                {Helpers.fmt_dt(run.started_at)}
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5">
                <%= if run.exit_status in [nil, ""] do %>
                  <span class="text-gray-400">—</span>
                <% else %>
                  <.status_badge status={run.exit_status} />
                <% end %>
              </td>
              <td class="border-b border-gray-100 px-4 py-2.5 text-right tabular-nums">{run.months_zipped}</td>
              <td class="border-b border-gray-100 px-4 py-2.5 text-right tabular-nums">{run.months_failed}</td>
            </tr>
          </tbody>
        </table>
        </div>
      <% end %>
    </div>
    """
  end

  # ---- Inline function components ---------------------------------------------

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

  attr :source, :map, required: true

  defp upload_flag(%{source: src} = assigns) do
    cond do
      not src.auto_upload ->
        ~H"""
        <span class="text-gray-400">○ off</span>
        """

      src.zipped_months == 0 ->
        ~H"""
        <span class="text-gray-400">—</span>
        """

      src.uploaded_months == src.zipped_months ->
        ~H"""
        <span class="inline-flex items-center gap-1 text-[12.5px] tabular-nums text-emerald-700">
          {@source.uploaded_months}/{@source.zipped_months}
        </span>
        """

      src.failed_uploads > 0 ->
        ~H"""
        <span class="inline-flex items-center gap-1 rounded bg-amber-100 px-1.5 py-0.5 text-[12.5px] tabular-nums text-amber-800">
          {@source.uploaded_months}/{@source.zipped_months} · {@source.failed_uploads} failed
        </span>
        """

      true ->
        ~H"""
        <span class="text-[12.5px] tabular-nums text-gray-400">
          {@source.uploaded_months}/{@source.zipped_months}
        </span>
        """
    end
  end
end
