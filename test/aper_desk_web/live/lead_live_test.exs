defmodule AperDeskWeb.LeadLiveTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Automation.OutboxEvent
  alias AperDesk.Crm
  alias AperDesk.Crm.Lead
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
    %{conn: sign_in(conn, user, studio), scope: scope, studio: studio}
  end

  describe "creating" do
    test "creates a lead and opens it", %{conn: conn, studio: studio} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/new")

      assert {:error, {:live_redirect, %{to: path}}} =
               view
               |> form("form", lead: %{title: "Summer wedding", shoot_type: "wedding"})
               |> render_submit()

      assert path =~ "/app/leads/"
      assert [lead] = Repo.all(from l in Lead, where: l.studio_id == ^studio.id)
      assert lead.title == "Summer wedding"
    end

    test "a pristine form shows no errors", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/leads/new")
      refute html =~ "can&#39;t be blank"
    end

    test "explains a plan limit rather than failing silently", %{
      conn: conn,
      studio: studio,
      scope: scope
    } do
      # Replace the generous fixture plan with one that is already full.
      Repo.delete_all(from s in AperDesk.Billing.Subscription, where: s.studio_id == ^studio.id)
      plan_fixture(studio, limits: %{"active_leads" => 1})
      lead_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      html = view |> form("form", lead: %{title: "One too many"}) |> render_submit()

      assert html =~ "Your plan allows 1 active leads"
    end
  end

  describe "the detail page" do
    setup %{scope: scope} do
      contact = contact_fixture(scope, %{"name" => "Anna Bell"})

      lead =
        lead_fixture(scope, %{
          "contact_id" => contact.id,
          "title" => "Summer wedding",
          "location" => "Villa Rosa"
        })

      %{lead: lead, contact: contact}
    end

    test "shows the enquiry and what is still missing", %{conn: conn, lead: lead} do
      {:ok, _view, html} = live(conn, ~p"/app/leads/#{lead}")

      assert html =~ "Anna Bell"
      assert html =~ "Villa Rosa"
      assert html =~ "Before this can be booked"
      assert html =~ "First reply sent"
    end

    test "moving a stage emits the domain event", %{conn: conn, lead: lead, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/#{lead}")

      # Two buttons offer this move — the topbar's next-step button and the chip
      # in the "move the lead" panel. Either should work; this drives the chip.
      html = view |> element("button.chip[phx-value-stage=contacted]") |> render_click()
      assert html =~ "Moved to Contacted"

      {:ok, reloaded} = Crm.fetch_lead(scope, lead.id)
      assert reloaded.stage == "contacted"

      assert Repo.exists?(
               from e in OutboxEvent,
                 where: e.subject_id == ^lead.id and e.name == "lead.stage_changed"
             ),
             "a move from the UI must emit the same event an API move would"
    end

    test "recording a reply stops the SLA clock", %{conn: conn, lead: lead, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/#{lead}")

      view |> element("button[phx-click=replied]") |> render_click()

      {:ok, reloaded} = Crm.fetch_lead(scope, lead.id)
      assert reloaded.first_responded_at
    end

    test "marking lost requires a reason", %{conn: conn, lead: lead, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/#{lead}")

      html =
        view
        |> form("form[phx-submit=lose]", lost: %{reason: "Chose someone else"})
        |> render_submit()

      assert html =~ "Marked lost"

      {:ok, reloaded} = Crm.fetch_lead(scope, lead.id)
      assert reloaded.stage == "lost"
      assert reloaded.lost_reason == "Chose someone else"
    end

    test "links back to the contact", %{conn: conn, lead: lead, contact: contact} do
      {:ok, _view, html} = live(conn, ~p"/app/leads/#{lead}")
      assert html =~ ~s(href="/app/contacts/#{contact.id}")
    end
  end
end
