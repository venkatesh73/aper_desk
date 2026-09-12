defmodule AperDeskWeb.RoleDashboardsTest do
  @moduledoc """
  Five roles, five different home screens.

  Not the same panels filtered: the assertions below check that each role gets
  the question it actually opens this screen to ask, and — just as importantly
  — that it does not get somebody else's.
  """
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.{Accounts, Operations, People, Repo, Scheduling}

  setup %{conn: conn} do
    %{user: owner, studio: studio, scope: owner_scope} = studio_fixture()
    plan_fixture(studio)
    %{conn: conn, studio: studio, owner: owner, owner_scope: owner_scope}
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

  defp dashboard(conn, user, studio) do
    {:ok, token, _} = Accounts.create_token(user, "session")

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:studio_id, studio.id)
    |> live(~p"/app")
  end

  test "the owner is asked whether the business is winning work", %{
    conn: conn,
    owner: owner,
    studio: studio,
    owner_scope: owner_scope
  } do
    {:ok, _} =
      AperDesk.Crm.create_lead(owner_scope, %{"title" => "A wedding", "source" => "referral"})

    {:ok, _view, html} = dashboard(conn, owner, studio)

    assert html =~ "Bookings by month"
    assert html =~ "Where the work comes from"
    assert html =~ "Quotes out"
    assert html =~ "Outstanding"
    refute html =~ "My week"
  end

  test "a photographer is asked what they are doing this week", %{
    conn: conn,
    studio: studio,
    owner_scope: owner_scope
  } do
    anna = member(studio, "Anna", "photographer")

    {:ok, starts} = DateTime.new(Date.utc_today(), ~T[10:00:00], "Etc/UTC")
    {:ok, ends} = DateTime.new(Date.utc_today(), ~T[16:00:00], "Etc/UTC")

    {:ok, _} =
      Scheduling.create_job(
        owner_scope,
        %{"title" => "MY OWN SHOOT", "starts_at" => starts, "ends_at" => ends},
        [%{user_id: anna.user.id}]
      )

    {:ok, _} =
      Scheduling.create_job(owner_scope, %{
        "title" => "SOMEBODY ELSES",
        "starts_at" => starts,
        "ends_at" => ends
      })

    {:ok, _view, html} = dashboard(conn, anna.user, studio)

    assert html =~ "My week"
    assert html =~ "MY OWN SHOOT"
    assert html =~ "My shoots"

    # Visibility has already narrowed the query; the dashboard inherits it.
    refute html =~ "SOMEBODY ELSES"
    refute html =~ "Outstanding"
    refute html =~ "Bookings by month"
  end

  test "finance is asked what is owed", %{conn: conn, studio: studio, owner_scope: owner_scope} do
    daniel = member(studio, "Daniel", "finance")

    invoice =
      invoice_fixture(owner_scope, %{"due_on" => Date.add(Date.utc_today(), 5)})

    {:ok, _} = AperDesk.Finance.send_invoice(owner_scope, invoice.id)

    {:ok, _view, html} = dashboard(conn, daniel.user, studio)

    assert html =~ "Cash due"
    assert html =~ "Crew waiting to be paid"
    assert html =~ invoice.reference
    assert html =~ "due in 5 days"
    refute html =~ "My week"
    refute html =~ "Bookings by month"
  end

  test "HR is asked who is away and who is half-onboarded", %{
    conn: conn,
    studio: studio,
    owner_scope: owner_scope
  } do
    sofia = member(studio, "Sofia", "hr")
    anna = member(studio, "Anna", "photographer")

    from = Date.add(Date.utc_today(), 20)

    {:ok, _} =
      People.request_leave(owner_scope, %{
        "user_id" => anna.user.id,
        "starts_on" => from,
        "ends_on" => Date.add(from, 3),
        "kind" => "holiday"
      })

    {:ok, _} = People.start_onboarding(sofia.scope, anna.membership.id)

    {:ok, _view, html} = dashboard(conn, sofia.user, studio)

    assert html =~ "Leave to decide"
    assert html =~ "Part-way through onboarding"
    assert html =~ "Contracts ending"
    assert html =~ "Anna"
    assert html =~ "leave request waiting"

    # HR has no lead.read, so no client pipeline reaches this screen at all.
    refute html =~ "Open leads"
    refute html =~ "Outstanding"
  end

  test "ops is asked what will go wrong on Saturday", %{
    conn: conn,
    studio: studio,
    owner_scope: owner_scope
  } do
    mira = member(studio, "Mira", "ops")

    {:ok, starts} = DateTime.new(Date.add(Date.utc_today(), 3), ~T[10:00:00], "Etc/UTC")
    {:ok, ends} = DateTime.new(Date.add(Date.utc_today(), 3), ~T[16:00:00], "Etc/UTC")

    {:ok, _} =
      Scheduling.create_job(owner_scope, %{
        "title" => "NO ADDRESS SHOOT",
        "starts_at" => starts,
        "ends_at" => ends
      })

    {:ok, body} =
      Operations.create_gear(owner_scope, %{"name" => "A7 IV #1", "category" => "body"})

    {:ok, _} =
      Operations.check_out(mira.scope, body.id, %{
        "due_back_on" => Date.add(Date.utc_today(), -2)
      })

    {:ok, _view, html} = dashboard(conn, mira.user, studio)

    assert html =~ "Nowhere written down"
    assert html =~ "NO ADDRESS SHOOT"
    assert html =~ "Kit overdue back"
    assert html =~ "A7 IV #1"
    assert html =~ "Double-booked"
    assert html =~ "kit overdue"

    refute html =~ "Outstanding"
    refute html =~ "Leave to decide"
  end

  test "every role's dashboard mounts with an empty studio", %{conn: conn, studio: studio} do
    for role <- ~w(photographer finance hr ops) do
      person = member(studio, "P#{System.unique_integer([:positive])}", role)

      # The blank-studio path is where a dashboard assembled from six contexts
      # falls over, and it is every studio's first day.
      assert {:ok, _view, html} = dashboard(conn, person.user, studio)
      assert html =~ "Good"
    end
  end
end
