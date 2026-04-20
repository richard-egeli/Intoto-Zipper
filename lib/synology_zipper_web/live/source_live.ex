defmodule SynologyZipperWeb.SourceLive do
  @moduledoc """
  Per-source page — config form + month grid + danger zone on one
  page. Ports `internal/web/templates/source.html` and
  `internal/web/web.go:handleSource*`.

  Events:
    * `"save"` — submits the config form. Handles rename (Elixir
      equivalent of Go's `RenameSource`) + upsert.
    * `"reset_month"` — `phx-click` with `source` / `month` params.
    * `"delete_source"` — fired by the danger-zone form after JS
      confirm; removes the source + history, navigates back to /.
    * `"toggle_auto_upload"` — `phx-change` on the checkbox wrapper;
      used to enable/disable the Drive folder ID input live.

  PubSub: subscribes to `"source:<name>"` for month + source events
  so the grid refreshes when the scheduler writes a month row.
  """

  use SynologyZipperWeb, :live_view

  import SynologyZipperWeb.Live.FormFields

  on_mount {SynologyZipperWeb.Live.Hooks, :overview}

  alias SynologyZipper.State
  alias SynologyZipper.State.Source
  alias SynologyZipperWeb.Live.Helpers

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case State.get_source(name) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "source not found: #{name}")
         |> push_navigate(to: ~p"/")}

      source ->
        if connected?(socket) do
          State.subscribe_source(name)
        end

        {:ok,
         socket
         |> assign(:page_title, name)
         |> assign(:original_name, name)
         |> assign(:source, source)
         |> assign_form(source)
         |> assign(:auto_upload_checked, source.auto_upload)
         |> assign(:months, State.list_months(name))}
    end
  end

  # ------------------------------------------------------------------ events --

  @impl true
  def handle_event("validate", %{"source" => params}, socket) do
    changeset =
      socket.assigns.source
      |> Source.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :source))
     |> assign(:auto_upload_checked, parse_bool(params["auto_upload"]))}
  end

  def handle_event("save", %{"source" => params}, socket) do
    orig = socket.assigns.original_name
    new_name = params["name"] |> String.trim()

    # Step 1 — rename if the name changed. This migrates all month
    # rows so upsert_source sees a matching row.
    rename_result =
      if orig != new_name and new_name != "" do
        State.rename_source(orig, new_name)
      else
        {:ok, socket.assigns.source}
      end

    case rename_result do
      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "rename failed: #{inspect(reason)}")}

      {:ok, _} ->
        case State.upsert_source(normalize_params(params)) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "source saved")
             |> push_navigate(to: ~p"/sources/#{updated.name}")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "could not save source")
             |> assign(:form, to_form(changeset, as: :source))
             |> assign(:auto_upload_checked, parse_bool(params["auto_upload"]))}
        end
    end
  end

  def handle_event("reset_month", %{"month" => month}, socket) do
    :ok = State.reset_month(socket.assigns.original_name, month)

    {:noreply,
     socket
     |> put_flash(:info, "month #{month} reset")
     |> assign(:months, State.list_months(socket.assigns.original_name))}
  end

  def handle_event("delete_source", _params, socket) do
    :ok = State.delete_source(socket.assigns.original_name)

    {:noreply,
     socket
     |> put_flash(:info, "source #{socket.assigns.original_name} deleted")
     |> push_navigate(to: ~p"/")}
  end

  # -------------------------------------------------------------- info / pubsub

  @impl true
  def handle_info({:source_changed, name}, %{assigns: %{original_name: name}} = socket) do
    source = State.get_source(name)

    {:noreply,
     socket
     |> assign(:source, source)
     |> assign_form(source)
     |> assign(:auto_upload_checked, source.auto_upload)}
  end

  def handle_info({:source_deleted, name}, %{assigns: %{original_name: name}} = socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_info({:month_changed, name, _m}, %{assigns: %{original_name: name}} = socket) do
    {:noreply, assign(socket, :months, State.list_months(name))}
  end

  def handle_info({:month_deleted, name, _m}, %{assigns: %{original_name: name}} = socket) do
    {:noreply, assign(socket, :months, State.list_months(name))}
  end

  # {:run_*, ...} handled by the shared hook.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ----------------------------------------------------------------- helpers --

  defp assign_form(socket, %Source{} = source) do
    assign(socket, :form, to_form(Source.changeset(source, %{}), as: :source))
  end

  defp normalize_params(params) do
    params
    |> Map.put("name", String.trim(params["name"] || ""))
    |> Map.put("path", String.trim(params["path"] || ""))
    |> Map.put("start_month", String.trim(params["start_month"] || ""))
    |> Map.put("move_to", String.trim(params["move_to"] || ""))
    |> Map.put("drive_folder_id", String.trim(params["drive_folder_id"] || ""))
    |> Map.put("auto_upload", parse_bool(params["auto_upload"]))
    |> Map.update("grace_days", 0, fn
      v when is_integer(v) -> v
      "" -> 0
      nil -> 0
      s when is_binary(s) -> case Integer.parse(s) do
        {n, _} -> n
        :error -> 0
      end
    end)
    |> Map.put_new("post_zip", "keep")
  end

  defp parse_bool(true), do: true
  defp parse_bool("true"), do: true
  defp parse_bool("on"), do: true
  defp parse_bool(_), do: false

  # ------------------------------------------------------------------- render --

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mb-3 text-[13px] text-gray-500">
      <.link navigate={~p"/"} class="text-blue-600 hover:underline">Overview</.link>
      <span class="mx-1">/</span>
      <span class="font-mono text-[12.5px]">{@original_name}</span>
    </div>

    <div class="mb-5 flex items-center justify-between">
      <h2 class="text-[22px] font-semibold tracking-tight text-gray-800">{@original_name}</h2>
    </div>

    <%= if msg = Phoenix.Flash.get(@flash, :info) do %>
      <div
        id="src-flash-info"
        phx-click={JS.hide(to: "#src-flash-info")}
        class="mb-4 cursor-pointer rounded-md border border-emerald-200 bg-emerald-50 px-4 py-2.5 text-[13.5px] text-emerald-800"
      >
        {msg}
      </div>
    <% end %>
    <%= if msg = Phoenix.Flash.get(@flash, :error) do %>
      <div
        id="src-flash-err"
        phx-click={JS.hide(to: "#src-flash-err")}
        class="mb-4 cursor-pointer rounded-md border border-red-200 bg-red-50 px-4 py-2.5 text-[13.5px] text-red-800"
      >
        {msg}
      </div>
    <% end %>

    <!-- ===== Configuration form =============================================== -->
    <div class="mb-5 rounded-md border border-gray-200 bg-white p-6 shadow-sm">
      <div class="mb-4">
        <h3 class="text-[14px] font-semibold uppercase tracking-wider text-gray-500">Configuration</h3>
      </div>

      <.form
        :let={f}
        for={@form}
        id="source-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-[580px] space-y-4"
      >
        <.field_text label="Name" field={f[:name]} required>
          Renaming moves this source's month history to the new name.
        </.field_text>

        <.field_text label="Path" field={f[:path]} required />

        <.field_text label="Start month" field={f[:start_month]} type="month" required />

        <.field_text label="Grace days" field={f[:grace_days]} type="number" min="0" />

        <div>
          <label class="mb-1 block text-[12px] font-medium text-gray-500">Post-zip action</label>
          <select
            name="source[post_zip]"
            id={f[:post_zip].id}
            class="h-[34px] w-full rounded-md border border-gray-300 bg-white px-2.5 text-[13.5px] text-gray-800 shadow-sm focus:border-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-600/10"
          >
            <option value="keep" selected={f[:post_zip].value in [nil, "", "keep"]}>keep</option>
            <option value="move" selected={f[:post_zip].value == "move"}>move</option>
          </select>
          <.field_errors field={f[:post_zip]} />
        </div>

        <.field_text
          label="Move-to (required if post-zip = move)"
          field={f[:move_to]}
        />

        <div>
          <label class="inline-flex items-center gap-2 text-[13px] text-gray-800">
            <input type="hidden" name="source[auto_upload]" value="false" />
            <input
              type="checkbox"
              name="source[auto_upload]"
              id={f[:auto_upload].id}
              value="true"
              checked={@auto_upload_checked}
              class="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-0"
            />
            <span>auto upload</span>
          </label>
          <.field_errors field={f[:auto_upload]} />
        </div>

        <div>
          <label class="mb-1 block text-[12px] font-medium text-gray-500">Drive folder ID</label>
          <input
            type="text"
            name="source[drive_folder_id]"
            id={f[:drive_folder_id].id}
            value={f[:drive_folder_id].value || ""}
            disabled={!@auto_upload_checked}
            class={[
              "h-[34px] w-full rounded-md border px-2.5 text-[13.5px] shadow-sm focus:border-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-600/10",
              @auto_upload_checked && "border-gray-300 bg-white text-gray-800",
              !@auto_upload_checked && "border-gray-200 bg-gray-100 text-gray-400"
            ]}
          />
          <p class="mt-1 text-[12px] text-gray-400">
            Paste the folder ID from its Drive URL. Required when auto upload is on.
          </p>
          <.field_errors field={f[:drive_folder_id]} />
        </div>

        <div class="mt-6 flex items-center gap-2 border-t border-gray-200 pt-4">
          <.link navigate={~p"/"} class="rounded-md border border-gray-300 bg-white px-3 py-1.5 text-[13px] text-gray-800 shadow-sm hover:bg-gray-50">
            Cancel
          </.link>
          <div class="flex-1"></div>
          <button
            type="submit"
            class="rounded-md border border-blue-600 bg-blue-600 px-3 py-1.5 text-[13px] font-medium text-white shadow-sm hover:bg-blue-700"
          >
            Save changes
          </button>
        </div>
      </.form>
    </div>

    <!-- ===== Months grid ====================================================== -->
    <div class="mb-5 rounded-md border border-gray-200 bg-white p-6 shadow-sm">
      <div class="mb-4">
        <h3 class="text-[14px] font-semibold uppercase tracking-wider text-gray-500">Months</h3>
      </div>

      <%= if @months == [] do %>
        <div class="rounded-md border border-dashed border-gray-300 bg-gray-50 px-4 py-10 text-center text-gray-400">
          No recorded months yet for this source.
        </div>
      <% else %>
        <div class="-mx-6 overflow-x-auto px-6">
        <table class="w-full min-w-[960px] border-separate border-spacing-0 text-left text-[13.5px]">
          <thead>
            <tr class="bg-gray-50 text-[11.5px] uppercase tracking-wider text-gray-500">
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Month</th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Status</th>
              <th class="border-b border-gray-200 px-4 py-2.5 text-right font-medium">Files</th>
              <th class="border-b border-gray-200 px-4 py-2.5 text-right font-medium">Size</th>
              <th class="border-b border-gray-200 px-4 py-2.5 text-right font-medium">Attempts</th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">
                Last attempt
              </th>
              <th class="border-b border-gray-200 px-4 py-2.5 font-medium">Error</th>
              <th class="whitespace-nowrap border-b border-gray-200 px-4 py-2.5 font-medium">Upload</th>
              <th class="border-b border-gray-200 px-4 py-2.5"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={m <- @months} id={"month-row-#{m.month}"} class="hover:bg-gray-50">
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 font-mono text-[12.5px] text-gray-500">
                {m.month}
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5">
                <.status_badge status={m.status} />
              </td>
              <td class="border-b border-gray-100 px-4 py-2.5 text-right tabular-nums">
                {m.file_count || 0}
              </td>
              <td class="border-b border-gray-100 px-4 py-2.5 text-right tabular-nums">
                {Helpers.human_bytes(m.zip_bytes || 0)}
              </td>
              <td class="border-b border-gray-100 px-4 py-2.5 text-right tabular-nums">
                {m.attempt_count}
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 font-mono text-[12.5px] text-gray-500">
                <%= if m.last_attempt_at do %>
                  {Helpers.fmt_dt(m.last_attempt_at)}
                <% else %>
                  <span class="text-gray-400">—</span>
                <% end %>
              </td>
              <td class="border-b border-gray-100 px-4 py-2.5 text-[12.5px] text-red-700 max-w-[320px]">
                {m.error}
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5">
                <.upload_cell month={m} />
              </td>
              <td class="whitespace-nowrap border-b border-gray-100 px-4 py-2.5 text-right">
                <button
                  type="button"
                  phx-click="reset_month"
                  phx-value-month={m.month}
                  data-confirm={"Reset #{@original_name} #{m.month}? It will be re-processed on the next run."}
                  class="rounded-md border border-gray-300 bg-white px-2.5 py-1 text-[12.5px] text-gray-800 shadow-sm hover:bg-gray-50"
                >
                  Reset
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        </div>
      <% end %>
    </div>

    <!-- ===== Danger zone ======================================================= -->
    <div class="mb-5 rounded-md border border-red-200 bg-white p-6 shadow-sm">
      <div class="mb-4">
        <h3 class="text-[14px] font-semibold uppercase tracking-wider text-red-700">Danger zone</h3>
      </div>
      <div class="flex items-center justify-between gap-4">
        <div>
          <strong class="text-[13.5px] text-gray-800">Delete this source</strong>
          <p class="mt-1 text-[12.5px] text-gray-500">
            Removes the config entry and all recorded month history. The zip files
            on disk are not touched.
          </p>
        </div>
        <button
          type="button"
          phx-click="delete_source"
          data-confirm={"Delete #{@original_name}? This cannot be undone."}
          class="rounded-md border border-red-200 bg-white px-3 py-1.5 text-[13px] font-medium text-red-700 shadow-sm hover:bg-red-50"
        >
          Delete source
        </button>
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

  attr :month, :map, required: true

  defp upload_cell(%{month: m} = assigns) do
    cond do
      is_binary(m.drive_file_id) and m.drive_file_id != "" ->
        tip =
          case m.uploaded_at do
            %DateTime{} = at ->
              "Uploaded #{Helpers.fmt_dt(at)} UTC · file #{Helpers.truncate(m.drive_file_id, 10)}"

            _ ->
              "Uploaded · file #{Helpers.truncate(m.drive_file_id, 10)}"
          end

        assigns = assign(assigns, :tip, tip)

        ~H"""
        <span
          title={@tip}
          class="inline-block rounded-full border border-emerald-200 bg-emerald-50 px-2 py-0.5 text-[11.5px] font-medium text-emerald-700"
        >
          uploaded
        </span>
        """

      is_binary(m.upload_error) and m.upload_error != "" ->
        tip = "#{m.upload_error} (attempts: #{m.upload_attempts})"
        assigns = assign(assigns, :tip, tip)

        ~H"""
        <span
          title={@tip}
          class="inline-block rounded-full border border-red-200 bg-red-50 px-2 py-0.5 text-[11.5px] font-medium text-red-700"
        >
          failed
        </span>
        """

      true ->
        ~H"""
        <span class="text-[12.5px] text-gray-400">pending</span>
        """
    end
  end
end
