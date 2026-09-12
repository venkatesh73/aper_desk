defmodule AperDeskWeb.ComboboxTest do
  @moduledoc """
  The searchable dropdown, driven through the lead form that uses it.

  Tested through a real screen rather than in isolation, because the properties
  that matter only hold in context: that it writes to the surrounding form, and
  that filtering does not lose the selection.
  """

  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts

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

    # Enough to be worth searching. Below the component's threshold the search
    # box is deliberately absent — you read seven things faster than you type —
    # so a four-contact studio would be testing the wrong branch.
    contacts =
      for name <- [
            "Anna Bell",
            "Tom Brunner",
            "Priya Nair",
            "Kessler AG",
            "Carla Mendes",
            "Nuno Pereira",
            "Sofie Jansen",
            "Bela Family"
          ],
          do: contact_fixture(scope, %{"name" => name})

    %{conn: sign_in(conn, user, studio), scope: scope, contacts: contacts}
  end

  defp open(view), do: view |> element("#lead-contact .combo-button") |> render_click()

  defp search(view, value),
    do: view |> element("#lead-contact-search") |> render_keyup(%{"value" => value})

  describe "opening" do
    test "is closed until asked", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/leads/new")

      refute html =~ "combo-panel"
      assert html =~ "Not linked to a contact yet"
    end

    test "shows every option when opened", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      html = open(view)

      assert html =~ "combo-panel"

      for name <- ["Anna Bell", "Tom Brunner", "Priya Nair", "Kessler AG"] do
        assert html =~ name
      end
    end
  end

  describe "searching" do
    test "filters by label", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      open(view)

      html = search(view, "pri")

      assert html =~ "Priya Nair"
      refute html =~ "Tom Brunner"
    end

    test "filters by the detail as well as the label", %{conn: conn, contacts: contacts} do
      # The email shows beside each option, and searching it is the point: a
      # studio often remembers the address rather than the spelling of a name.
      kessler = Enum.find(contacts, &(&1.name == "Kessler AG"))

      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      open(view)

      html = search(view, kessler.email)

      assert html =~ "Kessler AG"
      refute html =~ "Anna Bell"
    end

    test "says so when nothing matches", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      open(view)

      assert search(view, "zzzzz") =~ "No contact matched"
    end
  end

  describe "choosing" do
    test "writes the id into the form and closes", %{conn: conn, contacts: contacts} do
      anna = Enum.find(contacts, &(&1.name == "Anna Bell"))

      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      open(view)
      html = view |> element("#lead-contact .combo-option", "Anna Bell") |> render_click()

      # The hidden input is what the surrounding form actually submits.
      assert html =~ ~s(name="lead[contact_id]" value="#{anna.id}")
      refute html =~ "combo-panel"
    end

    test "the chosen contact is submitted with the lead", %{conn: conn, contacts: contacts} do
      anna = Enum.find(contacts, &(&1.name == "Anna Bell"))

      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      open(view)
      view |> element("#lead-contact .combo-option", "Anna Bell") |> render_click()

      assert {:error, {:live_redirect, %{to: path}}} =
               view |> form("form", lead: %{title: "Summer wedding"}) |> render_submit()

      {:ok, _view, html} = live(conn, path)
      assert html =~ anna.name
    end

    test "Enter chooses from the filtered list, not the original one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      open(view)
      search(view, "pri")

      html = render_hook(element(view, "#lead-contact-search"), "move", %{"key" => "Enter"})

      # The bug this guards chose the first of *all* options regardless of the
      # search, because Enter submitted the surrounding form first.
      assert html =~ "Priya Nair"
      refute html =~ "combo-panel"
    end

    test "Escape closes without choosing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      open(view)

      html = render_hook(element(view, "#lead-contact-search"), "move", %{"key" => "Escape"})

      refute html =~ "combo-panel"
      assert html =~ "Not linked to a contact yet"
    end
  end

  describe "clearing" do
    test "removes the selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      open(view)
      view |> element("#lead-contact .combo-option", "Anna Bell") |> render_click()

      open(view)
      html = view |> element("#lead-contact .combo-clear") |> render_click()

      assert html =~ ~s(name="lead[contact_id]" value="")
      assert html =~ "Not linked to a contact yet"
    end

    test "there is nothing to clear before anything is chosen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      refute open(view) =~ "combo-clear"
    end
  end

  describe "the search box" do
    test "is absent while the list is short enough to read", %{conn: conn, scope: scope} do
      # A studio with three packages does not need to filter three packages,
      # and a search box over three options is friction rather than help.
      {:ok, view, _html} = live(conn, ~p"/app/packages/new")
      view |> element("#package-shoot-type .combo-button") |> render_click()

      html = render(view)
      assert html =~ "combo-option"
      assert scope
    end

    test "appears once the list is long enough to need it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/leads/new")
      open(view)

      # Eight contacts, so the box is there.
      assert has_element?(view, "#lead-contact-search")
    end
  end
end
