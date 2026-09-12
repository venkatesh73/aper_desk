defmodule AperDeskWeb.SettingsLiveTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Authorization
  alias AperDesk.Billing
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

  describe "the studio profile" do
    test "saves and the change takes effect immediately", %{
      conn: conn,
      scope: scope,
      studio: studio
    } do
      {:ok, view, _html} = live(conn, ~p"/app/settings?section=studio")

      view
      |> form("form[phx-submit='save-studio']")
      |> render_submit(%{
        "studio" => %{
          "name" => "Aperture and Co",
          "city" => "Lisbon",
          "tagline" => "Documentary weddings"
        }
      })

      {:ok, reloaded} = Accounts.scope_for(scope.user, studio.id)
      assert reloaded.studio.name == "Aperture and Co"
      assert reloaded.studio.city == "Lisbon"

      # The header reads from the scope, so a stale one would show the old name
      # until a reload.
      assert render(view) =~ "Aperture and Co"
    end

    test "a bad value comes back on the field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/settings?section=studio")

      html =
        view
        |> form("form[phx-submit='save-studio']")
        |> render_submit(%{
          "studio" => %{"name" => "Still fine", "brand_color" => "not-a-colour"}
        })

      assert html =~ "must be a hex colour"
    end
  end

  describe "dates and money" do
    test "the sample follows the boxes before anything is saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/settings?section=formats")

      html =
        view
        |> form("form[phx-submit='save-studio']")
        |> render_change(%{"studio" => %{"date_format" => "iso", "time_format" => "12h"}})

      # The sample exists to answer "what will this look like" — reading the
      # saved value instead would answer the wrong question.
      assert html =~ "2026-09-10"
    end

    test "changing the currency changes what the rest of the app totals in", %{
      conn: conn,
      scope: scope,
      studio: studio
    } do
      {:ok, view, _html} = live(conn, ~p"/app/settings?section=formats")

      view
      |> form("form[phx-submit='save-studio']")
      |> render_submit(%{"studio" => %{"base_currency" => "EUR", "time_zone" => "Europe/Lisbon"}})

      {:ok, reloaded} = Accounts.scope_for(scope.user, studio.id)
      assert reloaded.studio.base_currency == "EUR"
      assert reloaded.currency == "EUR"
      assert reloaded.time_zone == "Europe/Lisbon"
    end

    test "the studio's own zone is offered even when it is off the curated list", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _studio} = Accounts.update_studio(scope, %{"time_zone" => "Indian/Mauritius"})

      {:ok, _view, html} = live(conn, ~p"/app/settings?section=formats")

      # A setting you cannot see is a setting you cannot change back.
      assert html =~ "Indian/Mauritius"
    end
  end

  describe "your account" do
    test "saves the name", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/app/settings?section=account")

      view
      |> form("form[phx-submit='save-account']")
      |> render_submit(%{"user" => %{"name" => "Ada R. Turner"}})

      assert Repo.reload!(user).name == "Ada R. Turner"
    end

    test "a wrong current password changes nothing", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/app/settings?section=account")
      before = Repo.reload!(user).hashed_password

      html =
        view
        |> form("form[phx-submit='change-password']")
        |> render_submit(%{
          "password" => %{
            "current" => "not my password",
            "new" => "a whole new passphrase",
            "confirmation" => "a whole new passphrase"
          }
        })

      assert html =~ "not your current password"
      assert Repo.reload!(user).hashed_password == before
    end

    test "mismatched new passwords change nothing", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/app/settings?section=account")
      before = Repo.reload!(user).hashed_password

      html =
        view
        |> form("form[phx-submit='change-password']")
        |> render_submit(%{
          "password" => %{
            "current" => valid_password(),
            "new" => "a whole new passphrase",
            "confirmation" => "a different passphrase"
          }
        })

      assert html =~ "do not match"
      assert Repo.reload!(user).hashed_password == before
    end

    test "a correct change signs this session out too", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/app/settings?section=account")

      view
      |> form("form[phx-submit='change-password']")
      |> render_submit(%{
        "password" => %{
          "current" => valid_password(),
          "new" => "a whole new passphrase",
          "confirmation" => "a whole new passphrase"
        }
      })

      # update_password/2 deletes every token, so holding this session open
      # would leave the browser with one the database no longer knows.
      assert_redirect(view, ~p"/sign-out")
      assert {:ok, _user} = Accounts.authenticate(user.email, "a whole new passphrase")
    end
  end

  describe "roles and permissions" do
    test "the matrix is drawn from the real permission table", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/settings?section=roles")

      assert html =~ "Approve crew payouts"
      assert html =~ "Photographer"

      # Spot-check the shape against the source of truth rather than against a
      # copy of it: a hand-written table is wrong the first time one moves.
      assert Authorization.holds?(:finance, :"payout.write")
      refute Authorization.holds?(:photographer, :"payout.write")
      assert Authorization.holds?(:owner, :"billing.write")
    end
  end

  describe "plan and usage" do
    test "shows the meters against the plan's own limits", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/settings?section=plan")

      assert html =~ "Storage"
      assert html =~ "100 GB"
    end

    test "cancelling keeps the period and can be resumed", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/app/settings?section=plan")

      html = view |> element("button[phx-click='cancel-plan']") |> render_click()
      assert html =~ "keep everything until the period ends"
      assert Billing.get_subscription(scope).cancel_at_period_end

      html = view |> element("button[phx-click='resume-plan']") |> render_click()
      assert html =~ "Resumed"
      refute Billing.get_subscription(scope).cancel_at_period_end
    end

    test "a downgrade that would break a limit is refused, in readable units", %{
      conn: conn,
      studio: studio,
      scope: scope
    } do
      # Already using storage that a smaller plan would not allow.
      gallery = gallery_fixture(scope, %{"title" => "Big one"})
      {:ok, _} = AperDesk.Galleries.deliver_gallery(scope, gallery.id)

      Repo.update_all(
        from(u in AperDesk.Billing.StudioUsage, where: u.studio_id == ^studio.id),
        set: [live_bytes: 50 * 1_073_741_824]
      )

      small =
        plan_fixture_only(%{
          "key" => "tiny",
          "name" => "Tiny",
          "limits" => %{"storage_bytes" => 1_073_741_824}
        })

      {:ok, view, _html} = live(conn, ~p"/app/settings?section=plan")

      html =
        view
        |> element("button[phx-value-plan='#{small.key}']")
        |> render_click()

      # Bytes are the right unit to enforce in and the wrong one to read.
      assert html =~ "1 GB of storage"
      assert html =~ "50 GB"
      refute html =~ "1073741824"
    end
  end

  describe "what each role may open" do
    test "a photographer is not offered billing or the studio profile", %{studio: studio} do
      {:ok, photographer} =
        Accounts.register_user(%{
          "name" => "Jonas Weber",
          "email" => "jonas-#{System.unique_integer([:positive])}@example.com",
          "password" => "correct horse battery staple"
        })

      Repo.insert!(
        AperDesk.Accounts.Membership.changeset(%AperDesk.Accounts.Membership{}, %{
          user_id: photographer.id,
          studio_id: studio.id,
          role: "photographer",
          status: "active"
        })
      )

      conn = sign_in(Phoenix.ConnTest.build_conn(), photographer, studio)
      {:ok, _view, html} = live(conn, ~p"/app/settings")

      # Filtered, not shown-and-refused: a tab that errors when opened has told
      # them something untrue about their own account.
      refute html =~ "Studio profile"
      refute html =~ "Plan and usage"
      assert html =~ "Your account"
      assert html =~ "Roles and permissions"
    end
  end

  # What `studio_fixture/1` registers the owner with.
  defp valid_password, do: "a sufficiently long passphrase"

  defp plan_fixture_only(attrs) do
    Repo.insert!(
      AperDesk.Billing.Plan.changeset(%AperDesk.Billing.Plan{}, %{
        key: attrs["key"],
        name: attrs["name"],
        tagline: "Smaller",
        monthly_price_cents: 500,
        yearly_price_cents: 5400,
        currency: "USD",
        public: true,
        features: [],
        limits: attrs["limits"]
      })
    )
  end
end
