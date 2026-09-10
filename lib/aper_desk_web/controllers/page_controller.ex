defmodule AperDeskWeb.PageController do
  use AperDeskWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
