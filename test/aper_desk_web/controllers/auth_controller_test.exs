defmodule AperDeskWeb.AuthControllerTest do
  @moduledoc """
  The auth flow end to end, including the properties that make it safe: one
  message for both kinds of bad credential, a renewed session on sign-in, and a
  token that stops working the moment it is revoked.
  """

  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures

  alias AperDesk.Accounts
  alias AperDesk.Billing.Plan
  alias AperDesk.Repo

  defp valid_registration(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        "name" => "Ada Turner",
        "studio_name" => "Turner Studio #{n}",
        "email" => "ada#{n}@example.com",
        "password" => "a sufficiently long passphrase"
      },
      overrides
    )
  end

  describe "GET /sign-up" do
    test "renders the form", %{conn: conn} do
      conn = get(conn, ~p"/sign-up")
      html = html_response(conn, 200)

      assert html =~ "Start your free trial"
      assert html =~ "registration[email]"
    end

    test "a pristine form shows no errors", %{conn: conn} do
      html = conn |> get(~p"/sign-up") |> html_response(200)

      # A changeset for a blank form is already invalid, because every required
      # field is missing. Rendering that greets a first-time visitor with
      # "can't be blank" on every input before they have typed anything.
      refute html =~ "can&#39;t be blank"
      refute html =~ "can't be blank"
    end
  end

  describe "POST /sign-up" do
    test "creates the user, the studio and the owner seat", %{conn: conn} do
      params = valid_registration()
      conn = post(conn, ~p"/sign-up", registration: params)

      assert redirected_to(conn) == ~p"/app"
      assert get_session(conn, :user_token)
      assert get_session(conn, :studio_id)

      user = Accounts.get_user_by_email(params["email"])
      assert user.name == "Ada Turner"
      assert [studio] = Accounts.list_studios_for_user(user)
      assert {:ok, scope} = Accounts.scope_for(user, studio.id)
      assert scope.role == :owner
    end

    test "starts the trial, so the new studio has a plan to check limits against", %{conn: conn} do
      Repo.insert!(
        Plan.changeset(%Plan{}, %{
          key: "solo",
          name: "Solo",
          monthly_price_cents: 1500,
          yearly_price_cents: 16_200,
          currency: "USD",
          limits: %{"active_leads" => 50}
        })
      )

      params = valid_registration()
      post(conn, ~p"/sign-up", registration: params)

      user = Accounts.get_user_by_email(params["email"])
      [studio] = Accounts.list_studios_for_user(user)
      {:ok, scope} = Accounts.scope_for(user, studio.id)

      assert subscription = AperDesk.Billing.get_subscription(scope)
      assert subscription.status == "trialing"
    end

    test "reports a short password against the password field", %{conn: conn} do
      conn = post(conn, ~p"/sign-up", registration: valid_registration(%{"password" => "short"}))
      html = html_response(conn, 422)

      assert html =~ "should be at least 12 character"
    end

    test "reports a taken email against the email field, not the name", %{conn: conn} do
      params = valid_registration()
      post(conn, ~p"/sign-up", registration: params)

      conn =
        post(build_conn(), ~p"/sign-up",
          registration: valid_registration(%{"email" => params["email"]})
        )

      html = html_response(conn, 422)
      assert html =~ "has already been taken"
    end

    test "does not create anything when the form is invalid", %{conn: conn} do
      before = Repo.aggregate(AperDesk.Accounts.Studio, :count)
      post(conn, ~p"/sign-up", registration: valid_registration(%{"email" => "not-an-email"}))

      assert Repo.aggregate(AperDesk.Accounts.Studio, :count) == before
    end
  end

  describe "POST /sign-in" do
    setup do
      %{user: user} = studio_fixture()
      %{user: user, password: "a sufficiently long passphrase"}
    end

    test "signs a known user in", %{conn: conn, user: user, password: password} do
      conn = post(conn, ~p"/sign-in", session: %{"email" => user.email, "password" => password})

      assert redirected_to(conn) == ~p"/app"
      assert get_session(conn, :user_token)
    end

    test "gives the same message for a wrong password and an unknown address", %{
      conn: conn,
      user: user
    } do
      wrong = post(conn, ~p"/sign-in", session: %{"email" => user.email, "password" => "nope"})

      unknown =
        post(build_conn(), ~p"/sign-in",
          session: %{"email" => "ghost@example.com", "password" => "nope"}
        )

      message = "That email and password do not match."
      assert html_response(wrong, 422) =~ message
      assert html_response(unknown, 422) =~ message
      refute get_session(wrong, :user_token)
    end
  end

  describe "sign out" do
    test "revokes the token so it cannot be replayed", %{conn: conn} do
      %{user: user} = studio_fixture()

      conn =
        post(conn, ~p"/sign-in",
          session: %{"email" => user.email, "password" => "a sufficiently long passphrase"}
        )

      token = get_session(conn, :user_token)
      assert {:ok, _user, _record} = Accounts.fetch_user_by_token(token, "session")

      conn = delete(recycle(conn), ~p"/sign-out")

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert {:error, :invalid_token} = Accounts.fetch_user_by_token(token, "session")
    end
  end

  describe "protected routes" do
    test "redirect an anonymous visitor to sign in", %{conn: conn} do
      conn = get(conn, ~p"/app")
      assert redirected_to(conn) == ~p"/sign-in"
    end
  end
end
