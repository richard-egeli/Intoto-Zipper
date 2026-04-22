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

  alias SynologyZipper.{Runner, State}
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
     |> assign(:active_zip, nil)
     |> assign(:active_upload, reconstruct_active_upload())
     |> refresh()}
  end

  @impl true
  def handle_event("reconcile_now", _params, socket) do
    # Run the reconcile on a detached Task so the LiveView stays
    # responsive — it can block for minutes on the md5 pass of each
    # pending zip. Progress surfaces via the normal `:upload_progress`
    # / `:upload_started` / `:upload_finished` PubSub feed that this
    # LiveView is already subscribed to, so the activity tile just
    # lights up as the reconcile proceeds.
    _ =
      Task.Supervisor.start_child(
        SynologyZipper.UploadTaskSupervisor,
        fn -> Runner.reconcile() end
      )

    {:noreply,
     put_flash(
       socket,
       :info,
       "Syncing with Drive — pending months will adopt existing files or re-upload. Watch the Live activity panel."
     )}
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

  # ---- Live activity events ---------------------------------------------------

  def handle_info({:zip_started, source, month}, socket) do
    {:noreply, assign(socket, :active_zip, %{source: source, month: month, bytes: 0})}
  end

  def handle_info({:zip_progress, source, month, bytes}, socket) do
    case socket.assigns.active_zip do
      %{source: ^source, month: ^month} = z ->
        {:noreply, assign(socket, :active_zip, %{z | bytes: bytes})}

      _ ->
        # Missed :zip_started (mounted mid-run) — rehydrate from the
        # event itself. Better to show the live tile with a fresh byte
        # count than nothing at all.
        {:noreply, assign(socket, :active_zip, %{source: source, month: month, bytes: bytes})}
    end
  end

  def handle_info({:zip_finished, source, month}, socket) do
    case socket.assigns.active_zip do
      %{source: ^source, month: ^month} -> {:noreply, assign(socket, :active_zip, nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:upload_started, source, month}, socket) do
    {:noreply,
     assign(socket, :active_upload, %{
       source: source,
       month: month,
       bytes: 0,
       total: upload_total_from_db(source, month),
       pct: 0
     })}
  end

  def handle_info({:upload_progress, source, month, bytes, total}, socket) do
    pct = if total > 0, do: min(div(bytes * 100, total), 100), else: 0

    {:noreply,
     assign(socket, :active_upload, %{
       source: source,
       month: month,
       bytes: bytes,
       total: total,
       pct: pct
     })}
  end

  def handle_info({:upload_finished, source, month}, socket) do
    case socket.assigns.active_upload do
      %{source: ^source, month: ^month} -> {:noreply, assign(socket, :active_upload, nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:run_end, _id, _status}, socket) do
    # Belt-and-suspenders: a clean run_end should have fired the
    # individual *_finished events, but if a run crashed mid-flight we
    # might be left with stale tiles. Clear them on run_end too. Also
    # refresh the sources list so any "running" badge flips to its
    # final status immediately — the hook sets `:running` to false on
    # this same event, so `display_last_status` now wants fresh data.
    {:noreply,
     socket
     |> assign(:active_zip, nil)
     |> assign(:active_upload, nil)
     |> refresh()}
  end

  # {:run_start, _} is handled by the shared hook.
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

  # On mount, if an upload was already in flight we can reconstruct
  # the tile from `upload_started_at` + `zip_bytes` (the upload total
  # is the size of the zip we're sending). Progress percentage is
  # unknown until the next `:upload_progress` broadcast; we seed it at
  # 0. No equivalent for the zip phase since there's no durable
  # "zipping now" marker — the first PubSub event will populate it.
  defp reconstruct_active_upload do
    case State.active_upload() do
      %{source_name: src, month: month, zip_bytes: total} when is_integer(total) ->
        %{source: src, month: month, bytes: 0, total: total, pct: 0}

      _ ->
        nil
    end
  end

  defp upload_total_from_db(source, month) do
    case State.get_month(source, month) do
      %{zip_bytes: bytes} when is_integer(bytes) and bytes > 0 -> bytes
      _ -> 0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mb-5 flex items-center justify-between">
      <h2 class="text-[22px] font-semibold tracking-tight text-gray-800">Overview</h2>
      <div class="flex items-center gap-2">
        <button
          type="button"
          phx-click="reconcile_now"
          title="Check Drive for existing uploads of zipped-but-pending months and adopt them without re-uploading"
          class="rounded-md border border-gray-300 bg-white px-3 py-1.5 text-[13px] font-medium text-gray-700 shadow-sm hover:bg-gray-50"
        >
          Sync with Drive
        </button>
        <.link
          navigate={~p"/sources/new"}
          class="rounded-md border border-blue-600 bg-blue-600 px-3 py-1.5 text-[13px] font-medium text-white shadow-sm hover:bg-blue-700"
        >
          + Add source
        </.link>
      </div>
    </div>

    <div
      :if={msg = Phoenix.Flash.get(@flash, :info)}
      id="ov-flash-info"
      phx-click={JS.hide(to: "#ov-flash-info")}
      class="mb-4 cursor-pointer rounded-md border border-emerald-200 bg-emerald-50 px-4 py-2.5 text-[13.5px] text-emerald-800"
    >
      {msg}
    </div>

    <.activity_panel zip={@active_zip} upload={@active_upload} running={@running} />

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
        <table class="w-full min-w-[640px] border-separate border-spacing-0 text-left text-[13.5px]">
          <thead>
            <tr class="bg-gray-50 text-[11.5px] uppercase tracking-wider text-gray-500">
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Name</th>
              <th class="border-b border-gray-200 px-4 py-2.5 font-medium">Path</th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Start</th>
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
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 font-mono text-[12.5px] text-gray-500">
                <%= if src.last_zipped_month == "" do %>
                  <span class="text-gray-400">—</span>
                <% else %>
                  {src.last_zipped_month}
                <% end %>
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5">
                <%= case display_last_status(src, @running) do %>
                  <% "" -> %>
                    <span class="text-gray-400">—</span>
                  <% status -> %>
                    <.status_badge status={status} />
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

  # A `status="failed"` row with no `finished_at` while the scheduler
  # is running is really the in-progress zip attempt — same idea as
  # `SourceLive.display_status/2`. Surface it as "running" so the
  # overview doesn't flash red during every tick.
  defp display_last_status(%{last_run_status: "failed", last_run_finished_at: nil}, true),
    do: "running"

  defp display_last_status(%{last_run_status: s}, _), do: s

  # ---- Inline function components ---------------------------------------------

  attr :zip, :map, default: nil
  attr :upload, :map, default: nil
  attr :running, :boolean, default: false

  defp activity_panel(%{zip: nil, upload: nil, running: false} = assigns) do
    # Truly idle: render nothing so the page looks the same as pre-feature.
    assigns = assign(assigns, :dummy, nil)

    ~H"""
    """
  end

  defp activity_panel(assigns) do
    ~H"""
    <div class="mb-5 rounded-md border border-gray-200 bg-white p-6 shadow-sm">
      <div class="mb-4 flex items-center justify-between">
        <h3 class="text-[14px] font-semibold uppercase tracking-wider text-gray-500">
          Live activity
        </h3>
        <span
          :if={@running and is_nil(@zip) and is_nil(@upload)}
          class="text-[12px] text-gray-400"
        >
          run in progress — waiting for work
        </span>
      </div>

      <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
        <.zip_tile zip={@zip} running={@running} />
        <.upload_tile upload={@upload} />
      </div>
    </div>
    """
  end

  attr :zip, :map, default: nil
  attr :running, :boolean, default: false

  defp zip_tile(%{zip: nil} = assigns) do
    ~H"""
    <div class="rounded-md border border-gray-200 bg-gray-50 px-4 py-3">
      <div class="mb-1 flex items-center gap-2">
        <span class="text-[11px] font-semibold uppercase tracking-wider text-gray-400">Zip</span>
        <%= if @running do %>
          <span class="text-[12px] text-gray-500">idle — no month zipping right now</span>
        <% else %>
          <span class="text-[12px] text-gray-400">scheduler idle</span>
        <% end %>
      </div>
      <div class="font-mono text-[12.5px] text-gray-400">—</div>
    </div>
    """
  end

  defp zip_tile(%{zip: %{source: src, month: month, bytes: bytes}} = assigns) do
    assigns = assign(assigns, source: src, month: month, bytes: bytes)

    ~H"""
    <div class="rounded-md border border-amber-200 bg-amber-50 px-4 py-3">
      <div class="mb-1 flex items-center gap-2">
        <span class="inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-amber-600" />
        <span class="text-[11px] font-semibold uppercase tracking-wider text-amber-700">Zipping</span>
      </div>
      <div class="flex items-baseline justify-between gap-3">
        <div class="min-w-0">
          <div class="truncate text-[13.5px] font-medium text-gray-800">{@source}</div>
          <div class="font-mono text-[12.5px] text-gray-500">{@month}</div>
        </div>
        <div class="text-right tabular-nums">
          <div class="text-[13.5px] font-semibold text-amber-800">{Helpers.human_bytes(@bytes)}</div>
          <div class="text-[11.5px] text-amber-600">written so far</div>
        </div>
      </div>
    </div>
    """
  end

  attr :upload, :map, default: nil

  defp upload_tile(%{upload: nil} = assigns) do
    ~H"""
    <div class="rounded-md border border-gray-200 bg-gray-50 px-4 py-3">
      <div class="mb-1">
        <span class="text-[11px] font-semibold uppercase tracking-wider text-gray-400">Upload</span>
        <span class="ml-2 text-[12px] text-gray-500">idle</span>
      </div>
      <div class="font-mono text-[12.5px] text-gray-400">—</div>
    </div>
    """
  end

  defp upload_tile(
         %{upload: %{source: src, month: month, bytes: bytes, total: total, pct: pct}} = assigns
       ) do
    assigns =
      assign(assigns,
        source: src,
        month: month,
        bytes: bytes,
        total: total,
        pct: pct,
        total_label: if(total > 0, do: Helpers.human_bytes(total), else: "—"),
        sent_label: Helpers.human_bytes(bytes)
      )

    ~H"""
    <div class="rounded-md border border-blue-200 bg-blue-50 px-4 py-3">
      <div class="mb-1 flex items-center gap-2">
        <span class="inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-blue-600" />
        <span class="text-[11px] font-semibold uppercase tracking-wider text-blue-700">Uploading</span>
      </div>
      <div class="mb-2 flex items-baseline justify-between gap-3">
        <div class="min-w-0">
          <div class="truncate text-[13.5px] font-medium text-gray-800">{@source}</div>
          <div class="font-mono text-[12.5px] text-gray-500">{@month}.zip</div>
        </div>
        <div class="text-right tabular-nums">
          <div class="text-[13.5px] font-semibold text-blue-800">{@pct}%</div>
          <div class="text-[11.5px] text-blue-600">
            {@sent_label} / {@total_label}
          </div>
        </div>
      </div>
      <div class="h-1.5 w-full overflow-hidden rounded-full bg-blue-100">
        <div
          class="h-full rounded-full bg-blue-500 transition-all duration-300"
          style={"width: #{@pct}%"}
        />
      </div>
    </div>
    """
  end

  attr :status, :string, required: true

  defp status_badge(%{status: status} = assigns) do
    {bg, text, border} =
      case status do
        s when s in ["zipped", "ok"] -> {"bg-emerald-50", "text-emerald-700", "border-emerald-200"}
        s when s in ["failed", "error"] -> {"bg-red-50", "text-red-700", "border-red-200"}
        s when s in ["partial", "running"] -> {"bg-amber-50", "text-amber-700", "border-amber-200"}
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
