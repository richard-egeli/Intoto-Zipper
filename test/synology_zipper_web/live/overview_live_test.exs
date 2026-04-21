defmodule SynologyZipperWeb.OverviewLiveTest do
  use SynologyZipperWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SynologyZipper.State

  setup do
    # The LiveView calls Scheduler.running?/1 via the layout hook. When
    # the scheduler process isn't running (test mode) the helper
    # swallows :exit — nothing to stub.
    :ok
  end

  test "renders empty state when there are no sources", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Overview"
    assert html =~ "No sources configured yet."
    assert html =~ "No runs recorded yet."
    # Header elements.
    assert html =~ "synology-zipper"
    assert html =~ "Run now"
    assert html =~ "idle"
  end

  # Retrofit test for the CSP header added to the :browser pipeline.
  # Tests-after, not TDD — pins the currently-shipping policy so future
  # pipeline edits can't silently weaken it.
  test "sets a Content-Security-Policy header on every page", %{conn: conn} do
    conn = get(conn, "/")
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "script-src 'self'"
    assert csp =~ "style-src 'self' 'unsafe-inline'"
    assert csp =~ "connect-src 'self' ws: wss:"
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "base-uri 'self'"
    assert csp =~ "form-action 'self'"
  end

  test "renders a source row that links to the source page", %{conn: conn} do
    {:ok, _} =
      State.upsert_source(%{
        name: "cams",
        path: "/mnt/cams",
        start_month: "2026-01",
        grace_days: 3,
        auto_upload: false
      })

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "cams"
    assert html =~ "/mnt/cams"
    assert html =~ ~s|href="/sources/cams"|
  end

  test "re-renders when a source is upserted (PubSub)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute render(view) =~ "cams"

    {:ok, _} =
      State.upsert_source(%{
        name: "cams",
        path: "/mnt/cams",
        start_month: "2026-01",
        grace_days: 3,
        auto_upload: false
      })

    # Allow the async broadcast to reach the LiveView process.
    :ok = render_eventually(view, "cams")
  end

  test "status pill flips to running on {:run_start, _}", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert render(view) =~ "idle"

    Phoenix.PubSub.broadcast(SynologyZipper.PubSub, "runs", {:run_start, 1})

    :ok = render_eventually(view, "running")
  end

  test "status pill flips back to idle on {:run_end, _, _}", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    Phoenix.PubSub.broadcast(SynologyZipper.PubSub, "runs", {:run_start, 1})
    :ok = render_eventually(view, "running")

    Phoenix.PubSub.broadcast(SynologyZipper.PubSub, "runs", {:run_end, 1, "ok"})
    :ok = render_eventually(view, "idle")
  end

  test "run_now event is handled without error (no scheduler running)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    # The shared hook catches :exit from Scheduler.run_now so this
    # succeeds even though no scheduler is booted in ConnCase.
    result =
      view
      |> element("button", "Run now")
      |> render_click()

    # result is the repainted HTML; pill is forced to "running" locally.
    assert result =~ "running"
  end

  # -- helpers -----------------------------------------------------------------

  # The PubSub broadcast hops through the LiveView process mailbox;
  # wait briefly for the re-render.
  defp render_eventually(view, needle, attempts \\ 20) do
    if render(view) =~ needle do
      :ok
    else
      if attempts == 0 do
        flunk("expected render to contain #{inspect(needle)} — got:\n#{render(view)}")
      else
        Process.sleep(10)
        render_eventually(view, needle, attempts - 1)
      end
    end
  end
end
