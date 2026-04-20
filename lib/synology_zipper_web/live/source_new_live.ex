defmodule SynologyZipperWeb.SourceNewLive do
  @moduledoc """
  New-source page at `/sources/new`. Ports
  `internal/web/templates/config_new.html` and
  `internal/web/web.go:handleConfigNew`/`handleConfigCreate`.

  On successful save, navigates to `/sources/:name`.
  """

  use SynologyZipperWeb, :live_view

  import SynologyZipperWeb.Live.FormFields

  on_mount {SynologyZipperWeb.Live.Hooks, :overview}

  alias SynologyZipper.State
  alias SynologyZipper.State.Source

  @defaults %Source{post_zip: "keep", grace_days: 3, auto_upload: false}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Add source")
     |> assign(:auto_upload_checked, false)
     |> assign_form(@defaults)}
  end

  @impl true
  def handle_event("validate", %{"source" => params}, socket) do
    changeset =
      @defaults
      |> Source.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :source))
     |> assign(:auto_upload_checked, parse_bool(params["auto_upload"]))}
  end

  def handle_event("save", %{"source" => params}, socket) do
    case State.upsert_source(normalize_params(params)) do
      {:ok, created} ->
        {:noreply,
         socket
         |> put_flash(:info, "source created")
         |> push_navigate(to: ~p"/sources/#{created.name}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "could not create source")
         |> assign(:form, to_form(changeset, as: :source))
         |> assign(:auto_upload_checked, parse_bool(params["auto_upload"]))}
    end
  end

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
    |> Map.update("grace_days", 3, fn
      v when is_integer(v) -> v
      "" -> 3
      nil -> 3
      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _} -> n
          :error -> 3
        end
    end)
    |> Map.put_new("post_zip", "keep")
  end

  defp parse_bool(true), do: true
  defp parse_bool("true"), do: true
  defp parse_bool("on"), do: true
  defp parse_bool(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mb-3 text-[13px] text-gray-500">
      <.link navigate={~p"/"} class="text-blue-600 hover:underline">Overview</.link>
      <span class="mx-1">/</span>
      <span>New source</span>
    </div>

    <div class="mb-5 flex items-center justify-between">
      <h2 class="text-[22px] font-semibold tracking-tight text-gray-800">Add source</h2>
    </div>

    <%= if msg = Phoenix.Flash.get(@flash, :error) do %>
      <div class="mb-4 rounded-md border border-red-200 bg-red-50 px-4 py-2.5 text-[13.5px] text-red-800">
        {msg}
      </div>
    <% end %>

    <div class="mb-5 rounded-md border border-gray-200 bg-white p-6 shadow-sm">
      <.form
        :let={f}
        for={@form}
        id="source-new-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-[580px] space-y-4"
      >
        <.field_text label="Name" field={f[:name]} required>
          Stable identifier used as the key for this source. Renaming later is possible but moves the history.
        </.field_text>

        <.field_text label="Path" field={f[:path]} required>
          Container-internal path. Must contain <code class="font-mono text-[11.5px]">YYYY-MM-DD</code> subfolders.
        </.field_text>

        <.field_text label="Start month" field={f[:start_month]} type="month" required>
          First month eligible for zipping. Earlier folders are ignored.
        </.field_text>

        <.field_text label="Grace days" field={f[:grace_days]} type="number" min="0">
          Days to wait after a month ends before zipping it. Useful if uploads can land late.
        </.field_text>

        <div>
          <label class="mb-1 block text-[12px] font-medium text-gray-500">Post-zip action</label>
          <select
            name="source[post_zip]"
            id={f[:post_zip].id}
            class="h-[34px] w-full rounded-md border border-gray-300 bg-white px-2.5 text-[13.5px] text-gray-800 shadow-sm focus:border-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-600/10"
          >
            <option value="keep" selected={f[:post_zip].value in [nil, "", "keep"]}>
              keep — leave the date folders alone
            </option>
            <option value="move" selected={f[:post_zip].value == "move"}>
              move — relocate them after zipping
            </option>
          </select>
          <p class="mt-1 text-[12px] text-gray-400">
            This tool will never delete source folders.
          </p>
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
            <span>auto upload (uploads each new zip to the Drive folder below)</span>
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
            placeholder="e.g. 1AbC2dEfGhIjKlMn..."
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
          <.link
            navigate={~p"/"}
            class="rounded-md border border-gray-300 bg-white px-3 py-1.5 text-[13px] text-gray-800 shadow-sm hover:bg-gray-50"
          >
            Cancel
          </.link>
          <div class="flex-1"></div>
          <button
            type="submit"
            class="rounded-md border border-blue-600 bg-blue-600 px-3 py-1.5 text-[13px] font-medium text-white shadow-sm hover:bg-blue-700"
          >
            Create source
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
