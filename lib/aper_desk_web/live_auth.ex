defmodule AperDeskWeb.LiveAuth do
  @moduledoc """
  Puts the caller's `%Scope{}` on the socket.

  The plug pipeline resolves a scope for the HTTP request that renders a
  LiveView, but the socket that connects afterwards is a separate process with
  only the session to go on — so the scope has to be built again here.

  Membership is read on every mount rather than trusted from the session. A
  session that was created before someone was removed from a studio, or
  demoted, must not keep granting the role it had when it was issued.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias AperDesk.Accounts
  alias AperDesk.Scope
  alias AperDeskWeb.Layouts

  def on_mount(:require_scope, _params, session, socket) do
    case scope_from_session(session) do
      {:ok, scope} ->
        {:cont, assign(socket, current_scope: scope)}

      :error ->
        {:halt,
         socket
         |> put_flash(:error, "Please sign in to continue.")
         |> redirect(to: "/sign-in")}
    end
  end

  def on_mount(:allow_anonymous, _params, session, socket) do
    scope =
      case scope_from_session(session) do
        {:ok, scope} -> scope
        :error -> Scope.public()
      end

    {:cont, assign(socket, current_scope: scope)}
  end

  defp scope_from_session(session) do
    with token when is_binary(token) <- session["user_token"],
         {:ok, user, _record} <- Accounts.fetch_user_by_token(token, "session"),
         {:ok, scope} <- studio_scope(user, session["studio_id"]) do
      {:ok, scope}
    else
      _ -> :error
    end
  end

  defp studio_scope(user, nil), do: Accounts.default_scope_for(user)
  defp studio_scope(user, studio_id), do: Accounts.scope_for(user, studio_id)

  @doc false
  def layouts, do: Layouts
end
