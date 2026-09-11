defmodule AperDeskWeb.GalleriesLiveTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Galleries

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

  describe "the list" do
    test "says so when there is nothing", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/galleries")
      assert html =~ "No galleries yet"
    end

    test "a gallery with nothing in it says what it is waiting for", %{conn: conn, scope: scope} do
      gallery_fixture(scope, %{"title" => "Anna and Ben"})

      {:ok, _view, html} = live(conn, ~p"/app/galleries")

      assert html =~ "Anna and Ben"
      assert html =~ "No photographs yet"
      assert html =~ "Waiting on the upload"
    end

    test "the status filter narrows the list", %{conn: conn, scope: scope} do
      gallery_fixture(scope, %{"title" => "A draft"})
      delivered = gallery_fixture(scope, %{"title" => "Handed over"})
      {:ok, _} = Galleries.deliver_gallery(scope, delivered.id)

      {:ok, view, _html} = live(conn, ~p"/app/galleries")

      html = view |> element("button[phx-value-status='delivered']") |> render_click()
      assert html =~ "Handed over"
      refute html =~ "A draft"
    end
  end

  describe "creating one" do
    test "lands on the new gallery, ready to upload", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/app/galleries/new")

      view
      |> form("form", gallery: %{})
      |> render_submit(%{"gallery" => %{"title" => "Cliff-top elopement"}})

      assert {:ok, [gallery]} = Galleries.list_galleries(scope)
      assert gallery.title == "Cliff-top elopement"
      assert_redirect(view, ~p"/app/galleries/#{gallery}")
    end

    test "a second gallery of the same name says so on the title", %{conn: conn, scope: scope} do
      gallery_fixture(scope, %{"title" => "Smith wedding"})

      {:ok, view, _html} = live(conn, ~p"/app/galleries/new")

      html =
        view
        |> form("form", gallery: %{})
        |> render_submit(%{"gallery" => %{"title" => "Smith wedding"}})

      # The clash is on the derived slug, which is not on this form — reported
      # there it would be invisible and the button would look broken.
      assert html =~ "is already used by another gallery"
      refute html =~ "has already been taken"
    end

    test "a pristine form does not shout about blank fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/galleries/new")
      refute html =~ "can&#39;t be blank"
    end
  end

  describe "size/1" do
    alias AperDeskWeb.GalleriesLive

    test "reads as a person would say it" do
      assert GalleriesLive.size(0) == "0 B"
      assert GalleriesLive.size(2048) == "2 KB"
      assert GalleriesLive.size(5_242_880) == "5 MB"
      assert GalleriesLive.size(8_160_437_862) == "7.6 GB"
    end
  end
end
