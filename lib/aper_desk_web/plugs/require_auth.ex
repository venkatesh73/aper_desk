defmodule AperDeskWeb.Plugs.RequireAuth do
  @moduledoc """
  Halts a request that has no studio-attached scope.

  Separate from `Authenticate` so that public pages — the landing page, a
  client's gallery link, the directory — can run the same pipeline and simply
  not include this plug.

  Answers in the format the caller asked for: JSON for the API, a redirect for
  the browser. A mobile client receiving an HTML login page instead of a 401 is
  a debugging afternoon nobody needs.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2, redirect: 2]

  alias AperDesk.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{studio: studio} = scope when not is_nil(studio) ->
        maybe_touch(scope)
        conn

      _ ->
        deny(conn)
    end
  end

  defp deny(conn) do
    if json_request?(conn) do
      conn
      |> put_status(:unauthorized)
      |> json(%{errors: [%{message: "unauthenticated"}]})
      |> halt()
    else
      conn
      |> redirect(to: "/sign-in")
      |> halt()
    end
  end

  defp json_request?(conn) do
    Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "json")) or
      String.starts_with?(conn.request_path, "/api")
  end

  # Cheap enough to do inline, and it drives the "last active" column on the
  # team screen without a separate tracking mechanism.
  defp maybe_touch(%Scope{membership: nil}), do: :ok

  defp maybe_touch(%Scope{membership: membership}),
    do: AperDesk.Accounts.touch_last_active(membership)
end
