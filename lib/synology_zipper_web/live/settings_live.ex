defmodule SynologyZipperWeb.SettingsLive do
  @moduledoc """
  /settings — upload the Google service-account JSON that the Drive
  uploader uses. The credential file is stored in the `settings`
  table; the Uploader GenServer reads it per-upload.

  Events:
    * `"validate_upload"` / `"save"` — file form submit with the JSON.
    * `"remove"` — clears the stored credentials.

  PubSub: subscribes to `settings_topic/0` so the status card refreshes
  if another tab uploads/removes credentials.
  """

  use SynologyZipperWeb, :live_view

  on_mount {SynologyZipperWeb.Live.Hooks, :settings}

  alias SynologyZipper.State

  # Google service-account JSON is small (usually < 3 KB), cap at 32 KB.
  @max_file_size 32 * 1024

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      State.subscribe_settings()
    end

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:credential_email, State.get_drive_credentials_email())
     |> allow_upload(:drive_json,
       accept: ~w(.json application/json),
       max_entries: 1,
       max_file_size: @max_file_size
     )}
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    [result] =
      consume_uploaded_entries(socket, :drive_json, fn %{path: path}, _entry ->
        case Elixir.File.read(path) do
          {:ok, body} ->
            case State.put_drive_credentials(body) do
              {:ok, _} -> {:ok, :saved}
              {:error, reason} -> {:ok, {:error, reason}}
            end

          {:error, reason} ->
            {:ok, {:error, {:read, reason}}}
        end
      end)

    socket =
      case result do
        :saved ->
          socket
          |> put_flash(:info, "Drive credentials saved.")
          |> assign(:credential_email, State.get_drive_credentials_email())

        {:error, :invalid_json} ->
          put_flash(socket, :error, "That file wasn't valid JSON.")

        {:error, :missing_required_fields} ->
          put_flash(socket, :error, "The JSON is missing `client_email` or `private_key` — make sure you exported a Google service-account key (not an OAuth client ID).")

        {:error, other} ->
          put_flash(socket, :error, "Could not save credentials: #{inspect(other)}")
      end

    {:noreply, socket}
  end

  def handle_event("remove", _params, socket) do
    :ok = State.delete_drive_credentials()

    {:noreply,
     socket
     |> put_flash(:info, "Drive credentials removed. Uploads are now disabled.")
     |> assign(:credential_email, nil)}
  end

  # ------------------------------------------------------------------ pubsub --

  @impl true
  def handle_info(:settings_changed, socket) do
    {:noreply, assign(socket, :credential_email, State.get_drive_credentials_email())}
  end

  # Other hook broadcasts we don't care about.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ------------------------------------------------------------------- render --

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mb-5 flex items-center justify-between">
      <h2 class="text-[22px] font-semibold tracking-tight text-gray-800">Settings</h2>
    </div>

    <%= if msg = Phoenix.Flash.get(@flash, :info) do %>
      <div class="mb-4 rounded-md border border-emerald-200 bg-emerald-50 px-4 py-2.5 text-[13.5px] text-emerald-800">
        {msg}
      </div>
    <% end %>
    <%= if msg = Phoenix.Flash.get(@flash, :error) do %>
      <div class="mb-4 rounded-md border border-red-200 bg-red-50 px-4 py-2.5 text-[13.5px] text-red-800">
        {msg}
      </div>
    <% end %>

    <!-- ===== Drive credentials card ========================================== -->
    <div class="mb-5 rounded-md border border-gray-200 bg-white p-6 shadow-sm">
      <div class="mb-4">
        <h3 class="text-[14px] font-semibold uppercase tracking-wider text-gray-500">Google Drive credentials</h3>
        <p class="mt-1 text-[12.5px] text-gray-500">
          Upload the JSON service-account key exported from the Google Cloud console.
          It's stored in the app's database and read by the uploader on each run —
          no files on disk, no environment variables.
        </p>
      </div>

      <%= if @credential_email do %>
        <div class="mb-4 rounded-md border border-emerald-200 bg-emerald-50 px-4 py-3 text-[13.5px]">
          <div class="font-medium text-emerald-800">Configured</div>
          <div class="mt-1 font-mono text-[12.5px] text-emerald-700">{@credential_email}</div>
        </div>
      <% else %>
        <div class="mb-4 rounded-md border border-amber-200 bg-amber-50 px-4 py-3 text-[13.5px] text-amber-800">
          No credentials uploaded yet. Uploads to Drive are disabled.
        </div>
      <% end %>

      <form
        id="drive-credentials-form"
        phx-submit="save"
        phx-change="validate_upload"
        class="flex flex-col gap-3"
      >
        <label
          for={@uploads.drive_json.ref}
          class="flex cursor-pointer items-center gap-3 rounded-md border border-dashed border-gray-300 bg-gray-50 px-4 py-6 text-[13px] text-gray-500 hover:border-blue-500 hover:text-blue-600"
        >
          <.live_file_input upload={@uploads.drive_json} class="hidden" />
          <span class="flex-1">
            <%= if Enum.empty?(@uploads.drive_json.entries) do %>
              Click to select a <code class="font-mono text-[11.5px]">*.json</code> service-account key…
            <% else %>
              <%= for entry <- @uploads.drive_json.entries do %>
                <span class="font-mono text-[12px] text-gray-700">{entry.client_name}</span>
                <span class="text-[11.5px] text-gray-400"> · {entry.client_size} bytes</span>
              <% end %>
            <% end %>
          </span>
          <span class="rounded-md border border-gray-300 bg-white px-3 py-1 text-[12px] font-medium text-gray-700 shadow-sm">
            Choose file
          </span>
        </label>

        <%= for entry <- @uploads.drive_json.entries, err <- upload_errors(@uploads.drive_json, entry) do %>
          <p class="text-[12.5px] text-red-700">{error_to_string(err)}</p>
        <% end %>

        <div class="flex items-center gap-2 border-t border-gray-200 pt-4">
          <%= if @credential_email do %>
            <button
              type="button"
              phx-click="remove"
              data-confirm="Remove the Drive credentials? Uploads will stop until a new key is uploaded."
              class="rounded-md border border-red-200 bg-white px-3 py-1.5 text-[13px] font-medium text-red-700 shadow-sm hover:bg-red-50"
            >
              Remove credentials
            </button>
          <% end %>
          <div class="flex-1"></div>
          <button
            type="submit"
            disabled={Enum.empty?(@uploads.drive_json.entries)}
            class={[
              "rounded-md border px-3 py-1.5 text-[13px] font-medium shadow-sm",
              Enum.empty?(@uploads.drive_json.entries) &&
                "cursor-not-allowed border-gray-200 bg-gray-100 text-gray-400",
              !Enum.empty?(@uploads.drive_json.entries) &&
                "border-blue-600 bg-blue-600 text-white hover:bg-blue-700"
            ]}
          >
            <%= if @credential_email, do: "Replace credentials", else: "Save credentials" %>
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp error_to_string(:too_large), do: "file is larger than 32 KB (the real JSON should be < 3 KB)"
  defp error_to_string(:too_many_files), do: "pick a single file"
  defp error_to_string(:not_accepted), do: "only .json files are accepted"
  defp error_to_string(other), do: to_string(other)
end
