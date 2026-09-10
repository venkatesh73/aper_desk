defmodule AperDeskWeb.CatalogScreensTest do
  @moduledoc """
  Packages, templates and automations.

  Several of these guard the same class of bug: a form field that is not a
  schema attribute must be carried across re-renders explicitly, or every
  keystroke resets it and the record saves without the value the user typed.
  """

  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import AperDeskWeb.ComboboxHelpers
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AperDesk.{Accounts, Automation, Catalog, Comms, Sales}
  alias AperDesk.Catalog.Package
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

  describe "packages" do
    test "shows an empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/packages")
      assert html =~ "No packages yet"
    end

    test "creates a package with the price typed in major units", %{conn: conn, studio: studio} do
      {:ok, view, _html} = live(conn, ~p"/app/packages/new")

      assert {:error, {:live_redirect, %{to: "/app/packages"}}} =
               view
               |> form("form",
                 package: %{name: "Full wedding day", price_major: "4500", price_currency: "USD"}
               )
               |> render_submit()

      assert [package] = Repo.all(from p in Package, where: p.studio_id == ^studio.id)
      assert package.name == "Full wedding day"
      # 4500 major units is 450000 minor units. Storing 4500 would be a
      # hundredfold under-charge.
      assert package.price_cents == 450_000
    end

    test "keeps the typed price across a re-render", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/packages/new")

      # The price box is not a schema field. Before it was tracked explicitly,
      # changing any other field wiped it and the package saved at zero.
      html =
        view
        |> form("form", package: %{name: "Full day", price_major: "4500"})
        |> render_change()

      assert html =~ ~s(value="4500")
    end

    test "archiving hides a package without deleting it", %{conn: conn, scope: scope} do
      {:ok, package} = Catalog.create_package(scope, %{"name" => "Half day"})

      {:ok, view, _html} = live(conn, ~p"/app/packages")
      view |> element("button[phx-value-id='#{package.id}'][phx-click=archive]") |> render_click()

      assert Repo.get!(Package, package.id).archived_at
    end
  end

  describe "templates" do
    test "email templates can be written and listed", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/app/templates/email/new")

      assert {:error, {:live_redirect, %{to: path}}} =
               view
               |> form("form",
                 template: %{
                   name: "Enquiry reply",
                   key: "enquiry_reply",
                   subject: "Hi {{first_name}}",
                   body: "Thanks for getting in touch."
                 }
               )
               |> render_submit()

      assert path =~ "tab=email"
      assert [template] = Comms.list_templates(scope)
      assert template.key == "enquiry_reply"
    end

    test "contract templates can be written", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/app/templates/contract/new")

      view
      |> form("form", template: %{name: "Standard terms", body: "The studio agrees to attend."})
      |> render_submit()

      assert [template] = Sales.list_templates(scope)
      assert template.name == "Standard terms"
    end

    test "the tabs show each kind separately", %{conn: conn, scope: scope} do
      {:ok, _} =
        Comms.create_template(scope, %{
          "key" => "k",
          "name" => "An email",
          "subject" => "s",
          "body" => "b"
        })

      {:ok, _} = Sales.create_template(scope, %{"name" => "A contract", "body" => "terms"})

      {:ok, view, html} = live(conn, ~p"/app/templates")
      assert html =~ "An email"
      refute html =~ "A contract"

      contracts = view |> element("button[phx-value-tab=contract]") |> render_click()
      assert contracts =~ "A contract"
      refute contracts =~ "An email"
    end

    test "archiving a template keeps it out of the list", %{conn: conn, scope: scope} do
      {:ok, template} =
        Comms.create_template(scope, %{
          "key" => "k",
          "name" => "Old",
          "subject" => "s",
          "body" => "b"
        })

      {:ok, view, _html} = live(conn, ~p"/app/templates")

      view
      |> element("button[phx-value-id='#{template.id}'][phx-click=archive]")
      |> render_click()

      assert Comms.list_templates(scope) == []
    end
  end

  describe "automations" do
    setup %{scope: scope} do
      {:ok, template} =
        Comms.create_template(scope, %{
          "key" => "reply",
          "name" => "Reply",
          "subject" => "Hi",
          "body" => "Body"
        })

      %{template: template}
    end

    # The template is chosen through the combobox rather than a select, so the
    # test drives it the way a person would: open, pick, submit.
    # Both the trigger and the template are searchable pickers now, so the test
    # drives them the way a person would.
    defp choose_workflow_basics(view, template) do
      choose(view, "workflow-trigger", "Lead created")
      choose(view, "workflow-template", template.name)
    end

    test "creates a workflow with its first step", %{conn: conn, scope: scope, template: template} do
      {:ok, view, _html} = live(conn, ~p"/app/automations/new")
      choose_workflow_basics(view, template)

      view
      |> form("form", workflow: %{name: "Reply to new leads", approval_mode: "ask"})
      |> render_submit()

      assert {:ok, [workflow]} = Automation.list_workflows(scope)
      assert workflow.name == "Reply to new leads"
      # A workflow with no steps is refused when active and useless when not,
      # so the form has to collect the first one.
      assert [step] = workflow.steps
      assert step.action == "send_template"
      assert step.config["template_id"] == template.id
    end

    test "a new workflow starts switched off and asking first", %{
      conn: conn,
      scope: scope,
      template: template
    } do
      {:ok, view, _html} = live(conn, ~p"/app/automations/new")
      choose_workflow_basics(view, template)

      view |> form("form", workflow: %{name: "W"}) |> render_submit()

      {:ok, [workflow]} = Automation.list_workflows(scope)
      refute workflow.active, "a rule must not start running before anyone has read it"
      assert workflow.approval_mode == "ask"
    end

    test "refuses to create one with no template chosen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/automations/new")

      choose(view, "workflow-trigger", "Lead created")
      html = view |> form("form", workflow: %{name: "W"}) |> render_submit()

      assert html =~ "Choose the template"
    end

    test "switching a workflow on and off", %{conn: conn, scope: scope, template: template} do
      {:ok, workflow} =
        Automation.create_workflow(scope, %{
          "name" => "W",
          "trigger_event" => "lead.created",
          "steps" => [
            %{
              "name" => "Send",
              "action" => "send_template",
              "config" => %{"template_id" => template.id}
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/app/automations")

      view
      |> element("button[phx-value-id='#{workflow.id}'][phx-click=toggle-workflow]")
      |> render_click()

      {:ok, [reloaded]} = Automation.list_workflows(scope)
      assert reloaded.active
    end

    test "creates a nurture sequence", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/app/automations/nurture/new")

      view
      |> form("form", sequence: %{name: "Quiet enquiries", enter_after_days: "5"})
      |> render_submit()

      assert [sequence] = Automation.list_sequences(scope)
      assert sequence.name == "Quiet enquiries"
      assert sequence.enter_after_days == 5
      assert sequence.exit_on_reply, "a sequence that keeps sending after a reply reads as spam"
    end

    test "the approvals tab is empty until something is parked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/automations")
      html = view |> element("button[phx-value-tab=approvals]") |> render_click()

      assert html =~ "Nothing is waiting on you"
    end
  end
end
