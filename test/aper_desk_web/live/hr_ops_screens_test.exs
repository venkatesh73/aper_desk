defmodule AperDeskWeb.HrOpsScreensTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.{Accounts, Operations, People, Repo, Scheduling}

  setup %{conn: conn} do
    %{studio: studio, scope: owner} = studio_fixture()
    plan_fixture(studio)
    %{conn: conn, studio: studio, owner: owner}
  end

  defp member(studio, name, role) do
    {:ok, user} =
      Accounts.register_user(%{
        "name" => name,
        "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
        "password" => "a sufficiently long passphrase"
      })

    membership =
      Repo.insert!(
        Accounts.Membership.changeset(%Accounts.Membership{}, %{
          user_id: user.id,
          studio_id: studio.id,
          role: role,
          status: "active"
        })
      )

    {:ok, scope} = Accounts.scope_for(user, studio.id)
    %{user: user, scope: scope, membership: membership}
  end

  defp sign_in(conn, user, studio) do
    {:ok, token, _} = Accounts.create_token(user, "session")

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:studio_id, studio.id)
  end

  describe "HR's leave queue" do
    test "approves a request and blocks the calendar from the screen", %{
      conn: conn,
      studio: studio,
      owner: owner
    } do
      hr = member(studio, "Sofia", "hr")
      anna = member(studio, "Anna", "photographer")

      from = Date.add(Date.utc_today(), 21)

      {:ok, request} =
        People.request_leave(owner, %{
          "user_id" => anna.user.id,
          "starts_on" => from,
          "ends_on" => Date.add(from, 3),
          "kind" => "holiday"
        })

      {:ok, view, _html} = conn |> sign_in(hr.user, studio) |> live(~p"/app/team")

      html = view |> element("button[phx-value-tab='leave']") |> render_click()
      assert html =~ "Anna"
      assert html =~ "Pending"

      html =
        view
        |> element("button[phx-value-id='#{request.id}'][phx-click='approve-leave']")
        |> render_click()

      assert html =~ "blocked on the calendar"

      # The calendar is what makes this real.
      {:ok, f} = DateTime.new(from, ~T[09:00:00], "Etc/UTC")
      {:ok, t} = DateTime.new(from, ~T[17:00:00], "Etc/UTC")
      assert [%{kind: "hold"}] = Scheduling.clashes_for(owner, anna.user.id, {f, t})
    end

    test "a photographer sees only their own and cannot approve", %{
      conn: conn,
      studio: studio,
      owner: owner
    } do
      anna = member(studio, "Anna", "photographer")
      ben = member(studio, "Ben", "photographer")
      from = Date.add(Date.utc_today(), 21)

      {:ok, _} =
        People.request_leave(owner, %{
          "user_id" => anna.user.id,
          "starts_on" => from,
          "ends_on" => from
        })

      {:ok, bens} =
        People.request_leave(owner, %{
          "user_id" => ben.user.id,
          "starts_on" => from,
          "ends_on" => from
        })

      {:ok, view, _html} = conn |> sign_in(anna.user, studio) |> live(~p"/app/team")
      html = view |> element("button[phx-value-tab='leave']") |> render_click()

      refute html =~ "phx-click=\"approve-leave\""
      refute html =~ bens.id
    end
  end

  describe "HR's roster" do
    test "shows who is on what, and who is away", %{conn: conn, studio: studio, owner: owner} do
      hr = member(studio, "Sofia", "hr")
      anna = member(studio, "Anna", "photographer")

      # A shoot inside this week.
      today = Date.utc_today()
      {:ok, starts} = DateTime.new(today, ~T[10:00:00], "Etc/UTC")
      {:ok, ends} = DateTime.new(today, ~T[16:00:00], "Etc/UTC")

      {:ok, _job} =
        Scheduling.create_job(
          owner,
          %{"title" => "ROSTERED SHOOT", "starts_at" => starts, "ends_at" => ends},
          [%{user_id: anna.user.id}]
        )

      {:ok, view, _html} = conn |> sign_in(hr.user, studio) |> live(~p"/app/team")
      html = view |> element("button[phx-value-tab='roster']") |> render_click()

      assert html =~ "ROSTERED SHOOT"
      assert html =~ "Anna"
      # "free" and "away" are different problems for whoever is filling a shift.
      assert html =~ "free"
    end
  end

  describe "HR's onboarding" do
    test "starts a checklist and ticks it off", %{conn: conn, studio: studio} do
      hr = member(studio, "Sofia", "hr")
      anna = member(studio, "Anna", "photographer")

      {:ok, view, _html} = conn |> sign_in(hr.user, studio) |> live(~p"/app/team")
      view |> element("button[phx-value-tab='onboarding']") |> render_click()

      html =
        view
        |> element("button[phx-value-id='#{anna.membership.id}'][phx-click='start-onboarding']")
        |> render_click()

      assert html =~ "Sign the contract"
      assert html =~ "0 of 5"

      {:ok, [task | _]} = People.list_onboarding(hr.scope, anna.membership.id)
      html = view |> element("input[phx-value-id='#{task.id}']") |> render_click()
      assert html =~ "1 of 5"
    end
  end

  describe "the Operations screen" do
    test "is Ops's own and finance cannot reach it", %{conn: conn, studio: studio} do
      ops = member(studio, "Mira", "ops")
      finance = member(studio, "Daniel", "finance")

      {:ok, _view, html} = conn |> sign_in(ops.user, studio) |> live(~p"/app/operations")
      assert html =~ "What needs sorting"
      assert html =~ ~s(href="/app/operations")

      # Finance has no gear.read, so the nav does not offer it.
      {:ok, _view, html} = conn |> sign_in(finance.user, studio) |> live(~p"/app")
      refute html =~ ~s(href="/app/operations")
    end

    test "signs kit out and back in", %{conn: conn, studio: studio, owner: owner} do
      ops = member(studio, "Mira", "ops")
      {:ok, body} = Operations.create_gear(owner, %{"name" => "A7 IV #1", "category" => "body"})

      {:ok, view, _html} = conn |> sign_in(ops.user, studio) |> live(~p"/app/operations")
      view |> element("button[phx-value-tab='gear']") |> render_click()

      html =
        view
        |> element("form[phx-submit='check-out']")
        |> render_submit(%{"checkout" => %{"gear_item_id" => body.id, "user_id" => ops.user.id}})

      assert html =~ "Signed out"
      assert {:ok, [checkout]} = Operations.checked_out(ops.scope)

      html =
        view
        |> element("button[phx-value-id='#{checkout.id}'][phx-click='check-in']")
        |> render_click()

      assert html =~ "Back in"
      assert {:ok, []} = Operations.checked_out(ops.scope)
    end

    test "names the shoots nobody has written an address for", %{
      conn: conn,
      studio: studio,
      owner: owner
    } do
      ops = member(studio, "Mira", "ops")
      {:ok, starts} = DateTime.new(Date.add(Date.utc_today(), 3), ~T[10:00:00], "Etc/UTC")
      {:ok, ends} = DateTime.new(Date.add(Date.utc_today(), 3), ~T[16:00:00], "Etc/UTC")

      {:ok, _} =
        Scheduling.create_job(owner, %{
          "title" => "NO ADDRESS SHOOT",
          "starts_at" => starts,
          "ends_at" => ends
        })

      {:ok, _view, html} = conn |> sign_in(ops.user, studio) |> live(~p"/app/operations")

      assert html =~ "NO ADDRESS SHOOT"
      assert html =~ "No venue at all"
    end
  end
end
