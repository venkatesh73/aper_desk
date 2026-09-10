defmodule AperDeskWeb.LeadsLiveTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Crm

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

  test "shows an empty state before any leads exist", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/app/leads")
    assert html =~ "No leads yet"
  end

  test "lists leads on the board grouped by stage", %{conn: conn, scope: scope} do
    contact = contact_fixture(scope, %{"name" => "Anna Bell"})
    lead_fixture(scope, %{"contact_id" => contact.id, "title" => "Summer wedding"})

    {:ok, _view, html} = live(conn, ~p"/app/leads")

    assert html =~ "Anna Bell"
    assert html =~ "Summer wedding"
    assert html =~ "New"
  end

  test "moving a lead goes through the context, so its event is emitted", %{
    conn: conn,
    scope: scope
  } do
    lead = lead_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/app/leads")

    html =
      view
      |> element("button[phx-value-id='#{lead.id}'][phx-value-stage='contacted']")
      |> render_click()

    assert html =~ "Lead moved to Contacted"

    {:ok, reloaded} = Crm.fetch_lead(scope, lead.id)
    assert reloaded.stage == "contacted"

    import Ecto.Query

    assert AperDesk.Repo.exists?(
             from e in AperDesk.Automation.OutboxEvent,
               where: e.subject_id == ^lead.id and e.name == "lead.stage_changed"
           ),
           "a UI move must emit the same event an API move would"
  end

  test "search filters the list", %{conn: conn, scope: scope} do
    lead_fixture(scope, %{"title" => "Wedding at Villa Rosa"})
    lead_fixture(scope, %{"title" => "Corporate headshots"})

    {:ok, view, _html} = live(conn, ~p"/app/leads")

    html = view |> form("form[phx-change=filter]", %{query: "Villa"}) |> render_change()

    assert html =~ "Villa Rosa"
    refute html =~ "Corporate headshots"
  end

  test "the table view renders the same leads", %{conn: conn, scope: scope} do
    lead_fixture(scope, %{"title" => "Summer wedding"})

    {:ok, view, _html} = live(conn, ~p"/app/leads")
    html = view |> element("button[phx-value-view=table]") |> render_click()

    assert html =~ "Summer wedding"
    assert html =~ "<table"
  end
end
