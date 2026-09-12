defmodule AperDeskWeb.DashboardLiveTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Repo

  defp sign_in(conn, user, studio) do
    {:ok, token, _} = Accounts.create_token(user, "session")

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:studio_id, studio.id)
  end

  defp as_role(user, studio, role) do
    membership =
      Repo.get_by!(AperDesk.Accounts.Membership, user_id: user.id, studio_id: studio.id)

    membership |> Ecto.Changeset.change(role: to_string(role)) |> Repo.update!()
  end

  setup do
    %{user: user, studio: studio} = studio_fixture()
    plan_fixture(studio, name: "Solo")
    %{user: user, studio: studio}
  end

  describe "access" do
    test "an anonymous visitor is redirected", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/app")
    end

    test "a signed-in owner sees their dashboard", %{conn: conn, user: user, studio: studio} do
      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app")

      assert html =~ "Good"
      assert html =~ studio.name
      assert html =~ user.name
    end
  end

  describe "role filtering" do
    test "an owner sees money on the dashboard and in the nav", %{
      conn: conn,
      user: user,
      studio: studio
    } do
      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app")

      assert html =~ "Outstanding"
      assert html =~ "Finance"
    end

    test "a photographer's browser never receives studio revenue", %{
      conn: conn,
      user: user,
      studio: studio
    } do
      as_role(user, studio, :photographer)
      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app")

      refute html =~ "Outstanding",
             "revenue must be filtered on the server, not hidden in the markup"

      refute html =~ ~s(href="/app/finance"),
             "a photographer should not be offered a screen they cannot open"

      assert html =~ ~s(href="/app/leads")
    end

    test "an hr user sees people but not client work", %{conn: conn, user: user, studio: studio} do
      as_role(user, studio, :hr)
      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app")

      assert html =~ ~s(href="/app/team")
      refute html =~ ~s(href="/app/galleries")
    end
  end

  describe "the plan panel" do
    test "shows meters on day one, before any counter row exists", %{
      conn: conn,
      user: user,
      studio: studio
    } do
      # A studio can have no studio_usage row at all: the triggers create one on
      # the first write that counts, and a restore or an import can leave it
      # missing. The panel must still render rather than blanking out.
      Repo.delete_all(from(u in AperDesk.Billing.StudioUsage, where: u.studio_id == ^studio.id))

      refute Repo.get(AperDesk.Billing.StudioUsage, studio.id)

      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app")

      assert html =~ "Your plan"
      assert html =~ "Solo"
      assert html =~ "Active leads"
    end

    test "shows storage in gigabytes, not bytes", %{conn: conn, user: user, studio: studio} do
      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app")

      assert html =~ "GB"
      refute html =~ "107374182400", "raw bytes are not a unit anyone can read"
    end

    test "omits limits that have nothing counting them", %{conn: conn, user: user, studio: studio} do
      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app")

      refute html =~ "Gallery window days",
             "a plan property is not a usage meter and must not read as one"
    end
  end
end
