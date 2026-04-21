defmodule SynologyZipperWeb.Router do
  use SynologyZipperWeb, :router

  # Tight CSP — the app loads only its own bundled JS/CSS and opens a
  # single WebSocket back to `self` for LiveView. `'unsafe-inline'` on
  # `style-src` is required because LiveView occasionally injects inline
  # `style` attributes (e.g. flash transitions).
  @csp "default-src 'self'; " <>
         "script-src 'self'; " <>
         "style-src 'self' 'unsafe-inline'; " <>
         "img-src 'self' data:; " <>
         "connect-src 'self' ws: wss:; " <>
         "base-uri 'self'; " <>
         "form-action 'self'; " <>
         "frame-ancestors 'none'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SynologyZipperWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SynologyZipperWeb do
    pipe_through :browser

    live "/", OverviewLive, :index
    live "/sources/new", SourceNewLive, :new
    live "/sources/:name", SourceLive, :show
    live "/runs", RunsLive, :index
    live "/settings", SettingsLive, :index
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:synology_zipper, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SynologyZipperWeb.Telemetry
    end
  end
end
