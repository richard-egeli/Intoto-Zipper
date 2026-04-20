defmodule SynologyZipperWeb.Live.FormFields do
  @moduledoc """
  Tiny form primitives shared by `SourceLive` and `SourceNewLive`.
  Keeps the default Phoenix form styling out of the way so the Go
  UI's look-and-feel can be mirrored verbatim.
  """

  use Phoenix.Component

  attr :label, :string, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :type, :string, default: "text"
  attr :required, :boolean, default: false
  attr :min, :string, default: nil
  slot :inner_block

  def field_text(assigns) do
    ~H"""
    <div>
      <label class="mb-1 block text-[12px] font-medium text-gray-500">{@label}</label>
      <input
        type={@type}
        name={@field.name}
        id={@field.id}
        value={@field.value || ""}
        required={@required}
        min={@min}
        class="h-[34px] w-full rounded-md border border-gray-300 bg-white px-2.5 text-[13.5px] text-gray-800 shadow-sm focus:border-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-600/10"
      />
      <p :if={@inner_block != []} class="mt-1 text-[12px] text-gray-400">
        {render_slot(@inner_block)}
      </p>
      <.field_errors field={@field} />
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  def field_errors(assigns) do
    errors = if Phoenix.Component.used_input?(assigns.field), do: assigns.field.errors, else: []
    assigns = assign(assigns, :errors, errors)

    ~H"""
    <p :for={err <- @errors} class="mt-1 text-[12px] text-red-700">
      {render_error(err)}
    </p>
    """
  end

  defp render_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
  end

  defp render_error(msg) when is_binary(msg), do: msg
end
