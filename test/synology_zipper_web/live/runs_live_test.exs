defmodule SynologyZipperWeb.RunsLiveTest do
  use SynologyZipperWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SynologyZipper.State

  test "renders the empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/runs")
    assert html =~ "Runs"
    assert html =~ "No runs recorded yet."
  end

  test "renders existing runs", %{conn: conn} do
    run = State.start_run(~U[2026-04-04 10:30:00Z])
    _ = State.finish_run(run.id, ~U[2026-04-04 10:31:00Z], "ok", 3, 0, "test")

    {:ok, _view, html} = live(conn, "/runs")
    assert html =~ "2026-04-04 10:30:00"
    assert html =~ "2026-04-04 10:31:00"
    assert html =~ "ok"
    assert html =~ "test"
  end

  test "re-renders when a new run is inserted (PubSub)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/runs")

    _ = State.start_run(~U[2026-04-04 11:00:00Z])

    :ok = render_eventually(view, "2026-04-04 11:00:00")
  end

  defp render_eventually(view, needle, attempts \\ 20) do
    if render(view) =~ needle do
      :ok
    else
      if attempts == 0 do
        flunk("expected render to contain #{inspect(needle)}")
      else
        Process.sleep(10)
        render_eventually(view, needle, attempts - 1)
      end
    end
  end
end
