defmodule AperDeskWeb.SetupLiveTest do
  @moduledoc """
  First-run setup, and the gate that makes it unavoidable.

  The gate matters more than the form: a studio that has not said which currency
  it reports in cannot be shown a dashboard, because every figure on it would be
  a guess.
  """

  use AperDeskWeb.ConnCase, async: true

  import AperDesk.DataCase, only: [errors_on: 1]
  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Accounts.Studio
  alias AperDesk.Formats
  alias AperDesk.Repo

  defp sign_in(conn, user, studio) do
    {:ok, token, _} = Accounts.create_token(user, "session")

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:studio_id, studio.id)
  end

  defp valid_setup(overrides \\ %{}) do
    Map.merge(
      %{
        "city" => "Zurich",
        "country_code" => "CH",
        "time_zone" => "Europe/Zurich",
        "base_currency" => "EUR",
        "date_format" => "dmy",
        "time_format" => "24h",
        "week_starts_on" => "monday",
        "reply_sla_minutes" => "240"
      },
      overrides
    )
  end

  describe "the gate" do
    setup do
      %{user: user, studio: studio} = studio_fixture(%{configured: false})
      plan_fixture(studio)
      %{user: user, studio: studio}
    end

    test "an unconfigured studio is sent to setup from anywhere in the app", %{
      conn: conn,
      user: user,
      studio: studio
    } do
      conn = sign_in(conn, user, studio)

      for path <- [~p"/app", ~p"/app/leads", ~p"/app/galleries"] do
        assert {:error, {:redirect, %{to: "/app/setup"}}} = live(conn, path)
      end
    end

    test "the setup screen itself does not redirect to itself", %{
      conn: conn,
      user: user,
      studio: studio
    } do
      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app/setup")
      assert html =~ "Set up #{studio.name}"
    end

    test "a configured studio is not sent to setup", %{conn: conn} do
      %{user: user, studio: studio} = studio_fixture()
      plan_fixture(studio)

      assert {:ok, _view, _html} = conn |> sign_in(user, studio) |> live(~p"/app")
    end

    test "an anonymous visitor is sent to sign in, not to setup", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/app/setup")
    end
  end

  describe "the form" do
    setup %{conn: conn} do
      %{user: user, studio: studio} = studio_fixture(%{configured: false})
      plan_fixture(studio)
      %{conn: sign_in(conn, user, studio), studio: studio, user: user}
    end

    test "saves the answers and lets the app through", %{conn: conn, studio: studio} do
      {:ok, view, _html} = live(conn, ~p"/app/setup")

      assert {:error, {:live_redirect, %{to: "/app"}}} =
               view |> form("form", setup: valid_setup()) |> render_submit()

      studio = Repo.get!(Studio, studio.id)
      assert studio.base_currency == "EUR"
      assert studio.time_zone == "Europe/Zurich"
      assert studio.city == "Zurich"
      assert Studio.configured?(studio)
    end

    test "requires the answers that cannot be guessed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/setup")

      html = view |> form("form", setup: valid_setup(%{"city" => ""})) |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "shows a worked example of the chosen date format", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/setup")

      dmy = view |> form("form", setup: valid_setup(%{"date_format" => "dmy"})) |> render_change()
      assert dmy =~ "10/09/2026"

      mdy = view |> form("form", setup: valid_setup(%{"date_format" => "mdy"})) |> render_change()
      assert mdy =~ "09/10/2026"

      iso = view |> form("form", setup: valid_setup(%{"date_format" => "iso"})) |> render_change()
      assert iso =~ "2026-09-10"
    end

    test "accepts the browser's time zone when nothing has been chosen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/setup")

      html = render_hook(view, "detected-timezone", %{"time_zone" => "Asia/Kolkata"})
      assert html =~ "Asia/Kolkata"
    end

    test "ignores a time zone the browser makes up", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/setup")

      html = render_hook(view, "detected-timezone", %{"time_zone" => "Nowhere/Fictional"})
      refute html =~ "Nowhere/Fictional"
    end

    test "only an owner may complete setup", %{conn: conn} do
      %{user: user, studio: studio} = studio_fixture(%{configured: false})
      plan_fixture(studio)

      membership =
        Repo.get_by!(AperDesk.Accounts.Membership, user_id: user.id, studio_id: studio.id)

      membership |> Ecto.Changeset.change(role: "photographer") |> Repo.update!()

      {:ok, view, _html} = conn |> sign_in(user, studio) |> live(~p"/app/setup")
      html = view |> form("form", setup: valid_setup()) |> render_submit()

      assert html =~ "Only an owner"
      refute Studio.configured?(Repo.get!(Studio, studio.id))
    end
  end

  describe "setup validation" do
    setup do
      %{studio: studio} = studio_fixture(%{configured: false})
      %{studio: studio}
    end

    # The time-zone select constrains the value in a browser, so an unresolvable
    # zone can only arrive from a hand-made request. The changeset is what has to
    # refuse it, and that is asserted directly rather than through the form.
    test "refuses a time zone that cannot be resolved", %{studio: studio} do
      changeset =
        Studio.setup_changeset(studio, valid_setup(%{"time_zone" => "Mars/Olympus_Mons"}))

      refute changeset.valid?
      assert "is not a known time zone" in errors_on(changeset).time_zone
    end

    test "refuses a currency the product does not sell in", %{studio: studio} do
      changeset = Studio.setup_changeset(studio, valid_setup(%{"base_currency" => "XYZ"}))
      refute changeset.valid?
      assert errors_on(changeset).base_currency != []
    end

    test "refuses a malformed country code", %{studio: studio} do
      changeset = Studio.setup_changeset(studio, valid_setup(%{"country_code" => "Switzerland"}))
      refute changeset.valid?
      assert "must be a two-letter country code" in errors_on(changeset).country_code
    end

    test "stamps setup as completed", %{studio: studio} do
      changeset = Studio.setup_changeset(studio, valid_setup())
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :setup_completed_at)
    end
  end

  describe "the pristine form" do
    setup %{conn: conn} do
      %{user: user, studio: studio} = studio_fixture(%{configured: false})
      plan_fixture(studio)
      %{conn: sign_in(conn, user, studio)}
    end

    test "shows no errors before anything is filled in", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/setup")

      refute html =~ "can&#39;t be blank"
      refute html =~ "can't be blank"
    end

    test "detecting the browser time zone does not mark the form validated", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/setup")

      # The hook fires on mount, before the visitor has typed anything. Marking
      # the form validated there greets them with errors on every field.
      html = render_hook(view, "detected-timezone", %{"time_zone" => "Asia/Kolkata"})

      assert html =~ "Asia/Kolkata"
      refute html =~ "can&#39;t be blank"
    end
  end

  describe "the flash banners" do
    test "the connection banners are rendered hidden", %{conn: conn} do
      %{user: user, studio: studio} = studio_fixture()
      plan_fixture(studio)

      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app")

      # They are revealed by LiveView when the socket drops. Shipping them
      # visible tells a visitor the server is unreachable while they read it.
      assert html =~ ~s(id="client-error")
      assert html =~ ~s(id="server-error")

      for id <- ["client-error", "server-error"] do
        [tag] = Regex.run(~r/<div[^>]*id="#{id}"[^>]*>/, html)
        assert tag =~ "hidden", "#{id} must be hidden until the socket disconnects"
      end
    end

    test "flash uses the design system's classes, not daisyUI's", %{conn: conn} do
      %{user: user, studio: studio} = studio_fixture()
      plan_fixture(studio)

      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app")

      assert html =~ ~s(class="flash-group")
      refute html =~ "toast toast-top", "daisyUI classes render unstyled here"
    end
  end

  describe "the sidebar" do
    test "does not carry a 'signed in as' box", %{conn: conn} do
      %{user: user, studio: studio} = studio_fixture()
      plan_fixture(studio)

      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app")

      refute html =~ "Signed in as"
      # The role still appears, in the footer beside the studio name.
      assert html =~ "Studio owner"
      assert html =~ studio.name
    end
  end

  describe "the chosen formats reach the screens" do
    test "the dashboard subtitle uses the studio's date format", %{conn: conn} do
      %{user: user, studio: studio} = studio_fixture()
      plan_fixture(studio)

      studio
      |> Ecto.Changeset.change(date_format: "iso", time_zone: "Etc/UTC")
      |> Repo.update!()

      {:ok, _view, html} = conn |> sign_in(user, studio) |> live(~p"/app")

      assert html =~ Date.to_iso8601(Date.utc_today())
    end
  end

  describe "the formats are actually used" do
    test "dates render in the studio's chosen format" do
      %{studio: studio} = studio_fixture()
      dmy = %Studio{studio | date_format: "dmy"}
      mdy = %Studio{studio | date_format: "mdy"}

      assert Formats.date(dmy, ~D[2026-09-10]) == "10/09/2026"
      assert Formats.date(mdy, ~D[2026-09-10]) == "09/10/2026"
    end

    test "times render in the studio's zone and format" do
      %{studio: studio} = studio_fixture()
      at = DateTime.new!(~D[2026-09-10], ~T[14:30:00], "Etc/UTC")

      utc24 = %Studio{studio | time_zone: "Etc/UTC", time_format: "24h"}
      utc12 = %Studio{studio | time_zone: "Etc/UTC", time_format: "12h"}
      kolkata = %Studio{studio | time_zone: "Asia/Kolkata", time_format: "24h"}

      assert Formats.time(utc24, at) == "14:30"
      assert Formats.time(utc12, at) == "2:30 pm"
      assert Formats.time(kolkata, at) == "20:00"
    end
  end
end
