defmodule AperDeskWeb.NotFoundError do
  @moduledoc """
  A page that genuinely is not there.

  Carries a 404 so Phoenix renders the error page and, more to the point, so
  crawlers drop the URL. A missing studio profile that answered 200 with an
  empty page would sit in the index forever pointing at nothing.
  """
  defexception [:message, plug_status: 404]
end
