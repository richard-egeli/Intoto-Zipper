defmodule SynologyZipperWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use SynologyZipperWeb, :controller` and
  `use SynologyZipperWeb, :live_view`.
  """
  use SynologyZipperWeb, :html

  embed_templates "layouts/*"
end
