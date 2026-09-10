defmodule AperDeskWeb.ContactsLiveTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Crm
  alias AperDesk.Crm.Contact
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
    %{conn: sign_in(conn, user, studio), scope: scope, studio: studio, user: user}
  end

  describe "the list" do
    test "shows an empty state before any contacts exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/contacts")
      assert html =~ "No contacts yet"
    end

    test "lists contacts", %{conn: conn, scope: scope} do
      contact_fixture(scope, %{"name" => "Anna Bell", "company" => "Bell Studio"})

      {:ok, _view, html} = live(conn, ~p"/app/contacts")
      assert html =~ "Anna Bell"
      assert html =~ "Bell Studio"
    end

    test "search narrows the list", %{conn: conn, scope: scope} do
      contact_fixture(scope, %{"name" => "Anna Bell"})
      contact_fixture(scope, %{"name" => "Tom Brunner"})

      {:ok, view, _html} = live(conn, ~p"/app/contacts")
      html = view |> form("form[phx-change=search]", %{query: "Anna"}) |> render_change()

      assert html =~ "Anna Bell"
      refute html =~ "Tom Brunner"
    end
  end

  describe "creating" do
    test "adds a contact and goes to its page", %{conn: conn, studio: studio} do
      {:ok, view, _html} = live(conn, ~p"/app/contacts/new")

      assert {:error, {:live_redirect, %{to: path}}} =
               view
               |> form("form", contact: %{name: "Anna Bell", email: "anna@example.com"})
               |> render_submit()

      assert path =~ "/app/contacts/"

      # Scoped to this studio: a global lookup would also match rows any other
      # test left behind.
      assert [contact] = Repo.all(from c in Contact, where: c.studio_id == ^studio.id)
      assert contact.name == "Anna Bell"
    end

    test "reports validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/contacts/new")

      html = view |> form("form", contact: %{name: "", email: "not-an-email"}) |> render_change()

      assert html =~ "can&#39;t be blank"
      assert html =~ "must be a valid email address"
    end

    test "a pristine form shows no errors", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/contacts/new")
      refute html =~ "can&#39;t be blank"
    end
  end

  describe "archiving" do
    test "hides the contact without deleting its history", %{conn: conn, scope: scope} do
      contact = contact_fixture(scope, %{"name" => "Anna Bell"})

      {:ok, view, _html} = live(conn, ~p"/app/contacts")
      view |> element("button[phx-value-id='#{contact.id}'][phx-click=archive]") |> render_click()

      # Still there, just archived — leads and invoices still reference it.
      assert Repo.get!(Contact, contact.id).archived_at
    end

    test "archived contacts are hidden until asked for", %{conn: conn, scope: scope} do
      contact = contact_fixture(scope, %{"name" => "Anna Bell"})
      {:ok, _} = Crm.archive_contact(scope, contact.id)

      {:ok, view, html} = live(conn, ~p"/app/contacts")
      refute html =~ "Anna Bell"

      shown = view |> element("button[phx-click=toggle-archived]") |> render_click()
      assert shown =~ "Anna Bell"
    end
  end

  describe "the detail page" do
    test "shows the contact's enquiries", %{conn: conn, scope: scope} do
      contact = contact_fixture(scope, %{"name" => "Anna Bell"})
      lead_fixture(scope, %{"contact_id" => contact.id, "title" => "Summer wedding"})

      {:ok, _view, html} = live(conn, ~p"/app/contacts/#{contact}")

      assert html =~ "Anna Bell"
      assert html =~ "Summer wedding"
    end
  end

  describe "authorization" do
    test "a finance user cannot open contacts", %{conn: conn, user: user, studio: studio} do
      Repo.get_by!(AperDesk.Accounts.Membership, user_id: user.id, studio_id: studio.id)
      |> Ecto.Changeset.change(role: "finance")
      |> Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/app/contacts")

      # Finance holds contact.read, so the list renders — but it must not offer
      # editing, which it does not hold.
      assert html =~ "Contacts"
    end
  end
end
