defmodule AperDeskWeb.TeamLiveTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Repo

  defp sign_in(conn, user, studio) do
    {:ok, token, _} = Accounts.create_token(user, "session")

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:studio_id, studio.id)
  end

  setup %{conn: conn} do
    %{user: user, studio: studio, scope: scope} = studio_fixture()
    plan_fixture(studio)
    %{conn: sign_in(conn, user, studio), scope: scope, user: user, studio: studio}
  end

  defp member_fixture(studio, attrs \\ %{}) do
    {:ok, user} =
      Accounts.register_user(%{
        "name" => Map.get(attrs, "name", "Jonas Weber"),
        "email" => "jonas-#{System.unique_integer([:positive])}@example.com",
        "password" => "correct horse battery staple"
      })

    Repo.insert!(
      AperDesk.Accounts.Membership.changeset(%AperDesk.Accounts.Membership{}, %{
        user_id: user.id,
        studio_id: studio.id,
        role: Map.get(attrs, "role", "photographer"),
        employment_type: Map.get(attrs, "employment_type", "staff"),
        status: "active"
      })
    )
  end

  describe "the roster" do
    test "lists the owner and what their role opens", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/team")

      assert html =~ "Ada Turner"
      assert html =~ "Owner"
      assert html =~ "1 on staff"
    end

    test "the only owner cannot be demoted or removed", %{conn: conn, user: user, scope: scope} do
      {:ok, [owner]} = Accounts.list_members(scope)

      {:ok, view, html} = live(conn, ~p"/app/team")
      assert html =~ "The only owner"

      html =
        view |> element("button[phx-value-id='#{owner.id}'][phx-click='edit']") |> render_click()

      # A studio locked out of its own billing has no way back in from inside
      # the product, so the controls are absent rather than offered and
      # refused: no role select, and no remove button.
      assert html =~ "cannot change"
      refute html =~ ~s(name="membership[role]" id)
      refute html =~ "phx-click=\"remove\""

      # And the context refuses it even if the form is bypassed.
      assert {:error, :last_owner} = Accounts.update_member(scope, owner.id, %{"role" => "ops"})
      assert {:error, :last_owner} = Accounts.remove_member(scope, owner.id)
      assert user.id == owner.user_id
    end

    test "changing a seat changes what that person can open", %{
      conn: conn,
      scope: scope,
      studio: studio
    } do
      membership = member_fixture(studio)

      {:ok, view, _html} = live(conn, ~p"/app/team")

      view
      |> element("button[phx-value-id='#{membership.id}'][phx-click='edit']")
      |> render_click()

      view
      |> form("form[phx-submit='save-member']")
      |> render_submit(%{
        "membership" => %{
          "role" => "finance",
          "employment_type" => "freelance",
          "day_rate_major" => "160"
        }
      })

      {:ok, members} = Accounts.list_members(scope)
      updated = Enum.find(members, &(&1.id == membership.id))

      assert updated.role == "finance"
      assert updated.employment_type == "freelance"
      assert updated.day_rate_cents == 16_000
    end

    test "removing someone keeps their name on their past work", %{
      conn: conn,
      scope: scope,
      studio: studio
    } do
      membership = member_fixture(studio)

      {:ok, view, _html} = live(conn, ~p"/app/team")

      view
      |> element("button[phx-value-id='#{membership.id}'][phx-click='edit']")
      |> render_click()

      view |> element("button[phx-click='remove']") |> render_click()

      # Marked left, never deleted — a deleted row turns their shoots and
      # invoices into "Unknown".
      reloaded = Repo.get!(AperDesk.Accounts.Membership, membership.id)
      assert reloaded.status == "left"

      {:ok, members} = Accounts.list_members(scope)
      refute Enum.any?(members, &(&1.id == membership.id))
    end
  end

  describe "invitations" do
    test "shows the link once and lists who is waiting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/team")

      html =
        view
        |> form("form[phx-submit='invite']")
        |> render_submit(%{"invitation" => %{"email" => "mira@example.com", "role" => "ops"}})

      assert html =~ "mira@example.com"
      assert [url] = Regex.run(~r{https?://[^"]+/invitations/[A-Za-z0-9_-]+}, html)
      assert url =~ "/invitations/"
    end

    test "a bad email comes back on the field, not as a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/team")

      html =
        view
        |> form("form[phx-submit='invite']")
        |> render_submit(%{"invitation" => %{"email" => "not-an-email", "role" => "ops"}})

      assert html =~ "must be a valid email address"
    end

    test "revoking removes it from the waiting list", %{conn: conn, scope: scope} do
      {:ok, _token, invitation} =
        Accounts.invite_member(scope, %{"email" => "mira@example.com", "role" => "ops"})

      {:ok, view, _html} = live(conn, ~p"/app/team")
      html = view |> element("button[phx-value-id='#{invitation.id}']") |> render_click()

      assert html =~ "Nobody outstanding"
      assert {:ok, []} = Accounts.list_invitations(scope)
    end
  end

  describe "taking the seat" do
    setup %{scope: scope} do
      {:ok, token, invitation} =
        Accounts.invite_member(scope, %{"email" => "mira@example.com", "role" => "ops"})

      %{token: token, invitation: invitation}
    end

    test "the link says whose studio it is and what seat", %{
      conn: conn,
      token: token,
      studio: studio
    } do
      html = conn |> get(~p"/invitations/#{token}") |> html_response(200)

      assert html =~ studio.name
      assert html =~ "Operations"
      assert html =~ "Leads, scheduling, galleries and comms"
    end

    test "signing in from the link joins the studio", %{token: token, scope: scope} do
      {:ok, user} =
        Accounts.register_user(%{
          "name" => "Mira Rocha",
          "email" => "mira@example.com",
          "password" => "correct horse battery staple"
        })

      # A fresh browser: the invitee is not the owner who sent it.
      conn =
        post(build_conn(), ~p"/invitations/#{token}", %{
          "session" => %{
            "email" => "mira@example.com",
            "password" => "correct horse battery staple"
          }
        })

      assert redirected_to(conn) == ~p"/app"

      {:ok, members} = Accounts.list_members(scope)
      assert Enum.any?(members, &(&1.user_id == user.id and &1.role == "ops"))
    end

    test "a signed-in user is warned when it was sent to someone else", %{
      conn: conn,
      token: token
    } do
      # `conn` is signed in as the owner, who is not mira@example.com. Taking
      # the seat would silently put the wrong person in it.
      html = conn |> get(~p"/invitations/#{token}") |> html_response(200)

      assert html =~ "This invitation was sent to mira@example.com"
      assert html =~ "Sign out"
    end

    test "a spent invitation says so rather than failing silently", %{conn: conn, token: token} do
      {:ok, user} =
        Accounts.register_user(%{
          "name" => "Mira Rocha",
          "email" => "mira@example.com",
          "password" => "correct horse battery staple"
        })

      {:ok, _membership} = Accounts.accept_invitation(token, user)

      html = conn |> get(~p"/invitations/#{token}") |> html_response(200)
      assert html =~ "already been used"
    end

    test "a made-up token opens nothing", %{conn: conn} do
      html = conn |> get(~p"/invitations/nonsense") |> html_response(200)
      assert html =~ "does not open anything"
    end

    test "looking at an invitation does not spend it", %{conn: conn, token: token, scope: scope} do
      conn |> get(~p"/invitations/#{token}") |> html_response(200)

      # Reading the link must not consume it — the invitee has to see whose
      # studio it is before deciding.
      assert {:ok, [_still_waiting]} = Accounts.list_invitations(scope)
    end
  end
end
