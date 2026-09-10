defmodule AperDeskWeb.Plugs.RequirePermission do
  @moduledoc """
  Gates a route on a permission from `AperDesk.Authorization`.

      pipe_through [:browser, :require_auth]
      plug AperDeskWeb.Plugs.RequirePermission, :"invoice.read"

  Contexts check permissions too, and deliberately so — this plug stops a
  request early and gives a clean error, but it is a convenience, not the
  boundary. The boundary is in the context, where it cannot be bypassed by a
  route someone forgot to annotate.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias AperDesk.Authorization

  def init(permission) when is_atom(permission), do: permission

  def call(conn, permission) do
    if Authorization.can?(conn.assigns[:current_scope], permission) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{errors: [%{message: "forbidden", permission: to_string(permission)}]})
      |> halt()
    end
  end
end
