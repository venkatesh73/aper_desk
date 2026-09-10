defmodule AperDeskWeb.PlugsTest do
  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures
  import Plug.Test

  alias AperDesk.Accounts.Guardian
  alias AperDeskWeb.Plugs.{Authenticate, RequireAuth, RequirePermission}

  setup do
    %{user: user, studio: studio, scope: scope} = studio_fixture()
    {:ok, tokens} = Guardian.sign_in(user, studio_id: studio.id)
    %{user: user, studio: studio, scope: scope, tokens: tokens}
  end

  defp api_conn(headers) do
    Enum.reduce(headers, conn(:get, "/api/graphql"), fn {k, v}, acc ->
      Plug.Conn.put_req_header(acc, k, v)
    end)
  end

  test "a bearer token resolves to a live scope", %{tokens: tokens, studio: studio} do
    conn =
      api_conn([{"authorization", "Bearer #{tokens.access_token}"}, {"x-studio-id", studio.id}])
      |> Authenticate.call([])

    scope = conn.assigns.current_scope
    assert scope.role == :owner
    assert scope.studio.id == studio.id
  end

  test "a refresh token is not accepted as a credential", %{tokens: tokens} do
    conn =
      api_conn([{"authorization", "Bearer #{tokens.refresh_token}"}])
      |> Authenticate.call([])

    assert conn.assigns.current_scope.studio == nil
  end

  test "an API request with no session does not crash" do
    # The API pipeline never fetches a session, and get_session/2 raises when it
    # has not been. This is the regression that made unauthenticated API calls
    # a 500 rather than a 401.
    conn = api_conn([]) |> Authenticate.call([])
    assert conn.assigns.current_scope.studio == nil
  end

  test "RequireAuth answers JSON for the API" do
    conn = api_conn([]) |> Authenticate.call([]) |> RequireAuth.call([])

    assert conn.halted
    assert conn.status == 401
    assert conn.resp_body =~ "unauthenticated"
  end

  test "RequirePermission gates on the role", %{tokens: tokens, studio: studio, scope: scope} do
    authed =
      api_conn([{"authorization", "Bearer #{tokens.access_token}"}, {"x-studio-id", studio.id}])
      |> Authenticate.call([])

    refute RequirePermission.call(authed, :"invoice.read").halted

    photographer = Plug.Conn.assign(authed, :current_scope, %{scope | role: :photographer})
    denied = RequirePermission.call(photographer, :"invoice.read")

    assert denied.halted
    assert denied.status == 403
  end
end
