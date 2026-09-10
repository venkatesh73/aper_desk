defmodule AperDeskWeb.FormLayoutTest do
  @moduledoc """
  Every form uses the shared layout.

  Not a style preference: before this, app forms were bare label and input
  siblings with a 1px gap between them, nothing grouped, and the submit button
  touching the last field. These assertions are what stops a new form being
  written that way again.
  """

  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Comms

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
    %{conn: sign_in(conn, user, studio), scope: scope}
  end

  @forms [
    {"new lead", "/app/leads/new"},
    {"new contact", "/app/contacts/new"},
    {"new package", "/app/packages/new"},
    {"new email template", "/app/templates/email/new"},
    {"new contract template", "/app/templates/contract/new"},
    {"new questionnaire", "/app/templates/questionnaire/new"},
    {"new workflow", "/app/automations/new"},
    {"new nurture sequence", "/app/automations/nurture/new"}
  ]

  for {name, path} <- @forms do
    test "the #{name} form uses the shared layout", %{conn: conn} do
      {:ok, _view, html} = live(conn, unquote(path))

      assert html =~ ~s(class="form"),
             "the form must carry the layout class or it has no vertical rhythm"

      assert html =~ ~s(class="field"),
             "controls must be wrapped in a field or the label sits on the input"

      assert html =~ ~s(class="form-actions"),
             "the submit row must be ruled off from the fields above it"

      assert html =~ "formpanel", "the form needs a panel with room to breathe"
    end
  end

  test "sections group long forms", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/app/leads/new")
    assert html =~ ~s(class="sect")
    assert html =~ "The enquiry"
    assert html =~ "The shoot"
  end

  test "a field carries its own hint and errors, not a loose sibling", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app/contacts/new")

    html = view |> form("form", contact: %{name: "", email: "nope"}) |> render_change()

    # The error must render inside the field, next to the control it belongs to.
    assert html =~ ~s(class="fe")
    assert html =~ "must be a valid email address"
  end

  test "checkboxes read as one line rather than a label above a control", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/app/contacts/new")
    assert html =~ ~s(class="checkfield")
  end

  test "the setup screen uses the same layout", %{conn: conn} do
    %{user: user, studio: studio} = studio_fixture(%{configured: false})
    plan_fixture(studio)

    {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app/setup")

    assert html =~ ~s(class="form")
    assert html =~ ~s(class="field")
  end

  test "a searchable picker is used where the list can grow", %{conn: conn, scope: scope} do
    {:ok, _} =
      Comms.create_template(scope, %{
        "key" => "k",
        "name" => "Reply",
        "subject" => "s",
        "body" => "b"
      })

    # Contacts and templates both grow without bound; a native select cannot be
    # filtered, so these must use the combobox.
    for path <- ["/app/leads/new", "/app/automations/new"] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ "combo-button", "#{path} should offer a searchable picker"
    end
  end
end
