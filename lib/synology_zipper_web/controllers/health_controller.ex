defmodule SynologyZipperWeb.HealthController do
  @moduledoc """
  Dead-simple health endpoint. Returns 200 `ok` with no DB, no
  session, no CSRF, no LiveView mount. Used by the Docker
  HEALTHCHECK — kept absolutely minimal so a busy NAS chugging
  through a zip+upload can still answer quickly enough to avoid
  spurious container restarts.
  """
  use SynologyZipperWeb, :controller

  def ok(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
