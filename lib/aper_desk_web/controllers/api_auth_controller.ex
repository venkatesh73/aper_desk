defmodule AperDeskWeb.ApiAuthController do
  @moduledoc """
  Token auth for the mobile client.

  `AuthController` is the browser's door: it renders forms and sets a session
  cookie. That is the wrong shape for a phone, which has no cookie jar worth
  relying on and needs a credential it can attach to a GraphQL request.

  So this controller issues the access/refresh pair described in
  `AperDesk.Accounts.Guardian`, and `AperDeskWeb.Plugs.Authenticate` accepts it
  as a bearer token on the same pipeline the browser uses. The two doors end at
  the same `%Scope{}`.
  """

  use AperDeskWeb, :controller

  alias AperDesk.Accounts
  alias AperDesk.Accounts.Guardian
  alias AperDesk.Scope

  @doc """
  Exchange email and password for a token pair.

  The studio is resolved here rather than left to the client: a token is only
  useful alongside a membership, and the client should not have to make a
  second round trip to discover which studio it is in.
  """
  def sign_in(conn, %{"email" => email, "password" => password} = params) do
    with {:ok, user} <- Accounts.authenticate(email, password),
         {:ok, scope} <- resolve_scope(user, params["studio_id"]),
         {:ok, tokens} <-
           Guardian.sign_in(user,
             studio_id: scope.studio && scope.studio.id,
             device_label: params["device_label"]
           ) do
      json(conn, Map.merge(tokens, %{user: user_json(user), studio: studio_json(scope)}))
    else
      {:error, :invalid_credentials} ->
        # One message for an unknown address and a wrong password alike —
        # telling them apart lets an attacker enumerate registered emails.
        error(conn, :unauthorized, "That email and password do not match.")

      {:error, :no_membership} ->
        error(conn, :forbidden, "This account is not a member of any studio.")

      {:error, _reason} ->
        error(conn, :unauthorized, "Could not sign in.")
    end
  end

  def sign_in(conn, _params),
    do: error(conn, :bad_request, "Email and password are required.")

  @doc "Exchange a refresh token for a fresh access token."
  def refresh(conn, %{"refresh_token" => refresh_token}) do
    case Guardian.refresh_session(refresh_token) do
      {:ok, tokens} -> json(conn, tokens)
      {:error, _reason} -> error(conn, :unauthorized, "That refresh token is no longer valid.")
    end
  end

  def refresh(conn, _params),
    do: error(conn, :bad_request, "A refresh token is required.")

  @doc """
  Revoke this device's refresh token.

  Succeeds even when the token is already gone: signing out twice is not an
  error, and reporting one invites clients to retry.
  """
  def sign_out(conn, params) do
    scope = conn.assigns[:current_scope] || Scope.public()

    case {scope.user, params["refresh_token"]} do
      {nil, _} -> json(conn, %{ok: true})
      {user, token} when is_binary(token) -> Guardian.sign_out(user, token)
      {user, _} -> Accounts.revoke_all_tokens(user, "refresh")
    end

    json(conn, %{ok: true})
  end

  ## Helpers

  # An explicit studio wins when the client asks for one, so a user who belongs
  # to several can pick; otherwise fall back to the studio they joined first.
  defp resolve_scope(user, nil), do: Accounts.default_scope_for(user)
  defp resolve_scope(user, studio_id), do: Accounts.scope_for(user, studio_id)

  defp user_json(user) do
    %{
      id: user.id,
      name: user.name,
      email: user.email,
      initials: initials(user.name)
    }
  end

  defp studio_json(%Scope{studio: nil}), do: nil

  defp studio_json(%Scope{studio: studio, role: role}) do
    %{
      id: studio.id,
      name: studio.name,
      role: role && Atom.to_string(role),
      currency: studio.base_currency,
      time_zone: studio.time_zone
    }
  end

  defp initials(nil), do: ""

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{errors: [%{message: message}]})
  end
end
