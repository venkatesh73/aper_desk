defmodule AperDeskWeb.GoogleAuthTest do
  @moduledoc """
  The OAuth callback's own checks, which do not require talking to Google.

  The `state` comparison is the important one: without it an attacker can
  complete their own Google flow and have the victim's browser deliver the
  resulting code, signing the victim into the attacker's account.
  """

  use AperDeskWeb.ConnCase, async: false

  alias AperDesk.Accounts.Google

  setup do
    original = Application.get_env(:aper_desk, Google)
    on_exit(fn -> Application.put_env(:aper_desk, Google, original || []) end)
    :ok
  end

  defp configure(client_id, secret) do
    Application.put_env(:aper_desk, Google, client_id: client_id, client_secret: secret)
  end

  describe "when unconfigured" do
    test "reports itself unconfigured" do
      configure(nil, nil)
      refute Google.configured?()
    end

    test "the button is not rendered on the auth screens", %{conn: conn} do
      configure(nil, nil)

      for path <- [~p"/sign-in", ~p"/sign-up"] do
        html = conn |> get(path) |> html_response(200)

        refute html =~ "with Google",
               "a button leading to Google's error page is worse than no button"
      end
    end

    test "starting the flow refuses rather than redirecting to a broken URL", %{conn: conn} do
      configure(nil, nil)
      conn = get(conn, ~p"/auth/google")

      assert redirected_to(conn) == ~p"/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not configured"
    end
  end

  describe "when configured" do
    setup do
      configure("test-client-id", "test-client-secret")
      :ok
    end

    test "the button appears on both auth screens", %{conn: conn} do
      assert conn |> get(~p"/sign-in") |> html_response(200) =~ "Sign in with Google"
      assert build_conn() |> get(~p"/sign-up") |> html_response(200) =~ "Sign up with Google"
    end

    test "redirects to Google with the expected parameters", %{conn: conn} do
      conn = get(conn, ~p"/auth/google")
      location = redirected_to(conn, 302)

      assert location =~ "accounts.google.com"
      assert location =~ "client_id=test-client-id"
      assert location =~ "response_type=code"
      assert location =~ "scope=openid+email+profile"
      assert location =~ "state="
      assert get_session(conn, :google_state)
    end

    test "the state is unpredictable", %{conn: conn} do
      first = conn |> get(~p"/auth/google") |> get_session(:google_state)
      second = build_conn() |> get(~p"/auth/google") |> get_session(:google_state)

      refute first == second
      assert byte_size(first) >= 32
    end
  end

  describe "the callback" do
    setup do
      configure("test-client-id", "test-client-secret")
      :ok
    end

    test "refuses a code with no state in the session", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/callback", %{"code" => "abc", "state" => "whatever"})

      assert redirected_to(conn) == ~p"/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
      refute get_session(conn, :user_token)
    end

    test "refuses a state that does not match the session", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{google_state: "the-real-state"})
        |> get(~p"/auth/google/callback", %{"code" => "abc", "state" => "an-attackers-state"})

      assert redirected_to(conn) == ~p"/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not be verified"
      refute get_session(conn, :user_token)
    end

    test "clears the state so a callback cannot be replayed", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{google_state: "the-real-state"})
        |> get(~p"/auth/google/callback", %{"code" => "abc", "state" => "nope"})

      refute get_session(conn, :google_state)
    end

    test "treats a cancelled sign-in as information, not an error", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{google_state: "state"})
        |> get(~p"/auth/google/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == ~p"/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "cancelled"
    end

    test "refuses a callback with neither a code nor an error", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/callback", %{})
      assert redirected_to(conn) == ~p"/sign-in"
      refute get_session(conn, :user_token)
    end
  end
end
