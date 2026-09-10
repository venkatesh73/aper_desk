defmodule AperDeskWeb.Plugs.Authenticate do
  @moduledoc """
  Resolves a request to a `%Scope{}` and puts it on the connection.

  Accepts either a bearer JWT (the mobile client) or a session token (the
  browser). Both end at the same place: `conn.assigns.current_scope`, built
  from a membership row that is read on every request.

  Reading the membership per request rather than trusting a studio id in the
  token is deliberate. Roles change, people are removed from studios, and a
  token issued last week must not still grant `owner` to someone who was
  demoted yesterday.

  This plug never rejects. It resolves what it can and lets
  `AperDeskWeb.Plugs.RequireAuth` decide what to do about an anonymous scope,
  so public pages can share the pipeline.
  """

  import Plug.Conn

  alias AperDesk.Accounts
  alias AperDesk.Accounts.Guardian
  alias AperDesk.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    case resolve(conn) do
      {:ok, scope} -> assign(conn, :current_scope, scope)
      :anonymous -> assign(conn, :current_scope, Scope.public())
    end
  end

  defp resolve(conn) do
    with {:ok, user} <- current_user(conn),
         {:ok, scope} <- scope_for(user, requested_studio(conn)) do
      {:ok, scope}
    else
      _ -> :anonymous
    end
  end

  defp current_user(conn) do
    case bearer_token(conn) do
      {:ok, token} -> user_from_jwt(token)
      :error -> user_from_session(conn)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  # Only access tokens are accepted here. A refresh token is for the refresh
  # endpoint alone — accepting one as a credential would hand a 60-day token
  # the reach of a 30-minute one.
  defp user_from_jwt(token) do
    with {:ok, claims} <- Guardian.decode_and_verify(token, %{"typ" => "access"}),
         {:ok, user} <- Guardian.resource_from_claims(claims) do
      {:ok, user}
    end
  end

  defp user_from_session(conn) do
    case session(conn, :user_token) do
      nil ->
        {:error, :no_session}

      token ->
        case Accounts.fetch_user_by_token(token, "session") do
          {:ok, user, _record} -> {:ok, user}
          error -> error
        end
    end
  end

  # The API pipeline does not fetch a session, and `get_session/2` raises
  # rather than returning nil when it has not been fetched. Guarding here is
  # what stops an unauthenticated API request becoming a 500 instead of a 401.
  defp session(conn, key) do
    if Map.has_key?(conn.private, :plug_session) do
      get_session(conn, key)
    else
      nil
    end
  end

  # The studio may be named by header (mobile), by session (browser), or not at
  # all — in which case the user's first studio is used.
  defp requested_studio(conn) do
    case get_req_header(conn, "x-studio-id") do
      [studio_id | _] -> studio_id
      [] -> session(conn, :studio_id)
    end
  end

  defp scope_for(user, nil), do: Accounts.default_scope_for(user)
  defp scope_for(user, studio_id), do: Accounts.scope_for(user, studio_id)
end
