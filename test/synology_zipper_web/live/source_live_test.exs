defmodule SynologyZipperWeb.SourceLiveTest do
  use SynologyZipperWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SynologyZipper.State

  defp seed!(attrs \\ %{}) do
    defaults = %{
      name: "cams",
      path: "/mnt/cams",
      start_month: "2026-01",
      grace_days: 3,
      post_zip: "keep",
      auto_upload: false
    }

    {:ok, s} = State.upsert_source(Map.merge(defaults, attrs))
    s
  end

  test "renders the form prefilled from the source", %{conn: conn} do
    seed!()
    {:ok, _view, html} = live(conn, "/sources/cams")
    assert html =~ "cams"
    assert html =~ "/mnt/cams"
    assert html =~ "Configuration"
    assert html =~ "Months"
    assert html =~ "Danger zone"
    # Breadcrumb back to /.
    assert html =~ ~s|href="/"|
  end

  test "redirects to / when the source doesn't exist", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/sources/missing")
  end

  test "save persists edits and navigates to the new name", %{conn: conn} do
    seed!()
    {:ok, view, _html} = live(conn, "/sources/cams")

    # drive_folder_id stays disabled while auto_upload is off — leave it out.
    assert {:error, {:live_redirect, %{to: "/sources/cams-new"}}} =
             view
             |> form("#source-form", %{
               "source" => %{
                 "name" => "cams-new",
                 "path" => "/mnt/cams",
                 "start_month" => "2026-02",
                 "grace_days" => "5",
                 "post_zip" => "keep",
                 "move_to" => "",
                 "auto_upload" => "false"
               }
             })
             |> render_submit()

    updated = State.get_source("cams-new")
    assert updated
    assert updated.start_month == "2026-02"
    assert updated.grace_days == 5
    # Old name is gone.
    refute State.get_source("cams")
  end

  test "reset_month deletes the row and re-renders without it", %{conn: conn} do
    seed!()
    now = ~U[2026-04-04 00:00:00Z]
    {:ok, _} = State.start_month_attempt("cams", "2026-03", now)
    {:ok, _} = State.mark_zipped("cams", "2026-03", now, "/tmp/x.zip", 10, 1)

    {:ok, view, _html} = live(conn, "/sources/cams")
    assert render(view) =~ "2026-03"

    view
    |> element(~s|button[phx-click="reset_month"][phx-value-month="2026-03"]|)
    |> render_click()

    # State is cleared.
    assert State.get_month("cams", "2026-03") == nil
    # After the delete + re-render, the row is gone.
    refute render(view) =~ ~s|id="month-row-2026-03"|
  end

  test "delete_source removes the source and navigates home", %{conn: conn} do
    seed!()
    {:ok, view, _html} = live(conn, "/sources/cams")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             view
             |> element("button", "Delete source")
             |> render_click()

    assert State.get_source("cams") == nil
  end

  test "PubSub month_changed triggers a re-render", %{conn: conn} do
    seed!()
    {:ok, view, _html} = live(conn, "/sources/cams")

    # Seed a month via the state context (broadcasts month_changed).
    now = ~U[2026-04-04 00:00:00Z]
    {:ok, _} = State.start_month_attempt("cams", "2026-03", now)

    :ok = render_eventually(view, "2026-03")
  end

  test "auto_upload toggle enables Drive folder ID input live", %{conn: conn} do
    seed!()
    {:ok, view, html} = live(conn, "/sources/cams")

    drive_input_re = ~r|<input[^>]*name="source\[drive_folder_id\]"[^>]*>|

    # On initial load the checkbox is unchecked and the Drive input is disabled.
    assert Regex.match?(drive_input_re, html)
    assert Regex.match?(~r|<input[^>]*name="source\[drive_folder_id\]"[^>]*\bdisabled\b|, html)

    # Flip auto_upload on via phx-change.
    html_after =
      view
      |> form("#source-form", %{
        "source" => %{
          "name" => "cams",
          "path" => "/mnt/cams",
          "start_month" => "2026-01",
          "grace_days" => "3",
          "post_zip" => "keep",
          "move_to" => "",
          "auto_upload" => "true"
        }
      })
      |> render_change()

    # The Drive input must still render and no longer carry `disabled`.
    assert Regex.match?(drive_input_re, html_after)
    refute Regex.match?(~r|<input[^>]*name="source\[drive_folder_id\]"[^>]*\bdisabled\b|, html_after)
  end

  # Wait briefly for async PubSub re-renders.
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
