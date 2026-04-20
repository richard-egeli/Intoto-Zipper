defmodule SynologyZipperWeb.Live.Hooks do
  @moduledoc """
  `on_mount` hook shared by every LiveView. Responsibilities:

    * Seeds the layout assigns — `:active_nav`, `:running`,
      `:banner_warning`. These are used by
      `lib/synology_zipper_web/components/layouts/app.html.heex`.
    * Subscribes the LiveView process to the `"runs"` PubSub topic so
      the status pill updates live when the scheduler broadcasts
      `{:run_start, id}` / `{:run_end, id, status}`.
    * Attaches a global `handle_event("run_now", _, socket)` handler
      so the "Run now" button in the header works from any page.

  Each LiveView picks its nav tab via the mount arg passed to
  `on_mount/4`, e.g. `on_mount {Hooks, :overview}`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias SynologyZipperWeb.Live.Helpers

  @pubsub SynologyZipper.PubSub

  def on_mount(nav, _params, _session, socket) when is_atom(nav) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, "runs")
    end

    socket =
      socket
      |> assign(:active_nav, Atom.to_string(nav))
      |> assign(:running, Helpers.scheduler_running?())
      |> assign(:banner_warning, Helpers.banner_warning())
      |> attach_hook(:run_now, :handle_event, &handle_run_now/3)
      |> attach_hook(:run_status, :handle_info, &handle_run_status/2)

    {:cont, socket}
  end

  defp handle_run_now("run_now", _params, socket) do
    # Non-blocking — the scheduler GenServer schedules the work on its
    # own process; this call returns immediately.
    try do
      SynologyZipper.Scheduler.run_now()
    catch
      :exit, _ -> :ok
    end

    {:halt, assign(socket, :running, true)}
  end

  defp handle_run_now(_event, _params, socket), do: {:cont, socket}

  defp handle_run_status({:run_start, _id}, socket) do
    {:cont, assign(socket, :running, true)}
  end

  defp handle_run_status({:run_end, _id, _status}, socket) do
    {:cont, assign(socket, :running, false)}
  end

  defp handle_run_status(_msg, socket), do: {:cont, socket}
end
