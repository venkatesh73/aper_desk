defmodule AperDeskWeb.CalendarLiveTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Scheduling

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

  describe "the month grid" do
    test "shows an empty month without inventing events", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/calendar")

      assert html =~ "Nothing double-booked"
      assert html =~ "No holds about to lapse"
    end

    test "draws a booked shoot on its own day", %{conn: conn, scope: scope} do
      job = job_fixture(scope, %{"title" => "Anna and Ben"})

      {:ok, _view, html} =
        live(conn, ~p"/app/calendar?year=#{job.starts_at.year}&month=#{job.starts_at.month}")

      assert html =~ "Anna and Ben"
    end

    test "covers whole weeks, so every grid row has seven days", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/calendar")
      count = view |> render() |> then(&Regex.scan(~r/class="[^"]*\bday\b/, &1)) |> length()

      assert rem(count, 7) == 0
      assert count in [28, 35, 42]
    end

    test "weekday headings follow the studio's chosen first day", %{conn: conn, scope: scope} do
      {:ok, _studio} = Accounts.update_studio(scope, %{"week_starts_on" => "sunday"})
      {:ok, _view, html} = live(conn, ~p"/app/calendar")

      [first | _] =
        Regex.run(~r/<div class="dow">\s*<span>(\w+)<\/span>/, html, capture: :all_but_first)

      assert first == "Sun"
    end
  end

  describe "the side panels" do
    test "names the two commitments behind a clash", %{conn: conn, scope: scope, user: user} do
      job = job_fixture(scope, %{"title" => "Anna and Ben"}, [%{user_id: user.id}])

      # A hold does not block, so this second commitment lands on the same
      # person and window — which is exactly the state the panel exists for.
      {:ok, _hold} =
        Scheduling.assign(scope, %{
          "user_id" => user.id,
          "kind" => "hold",
          "label" => "Pencilled date",
          "period" => {job.starts_at, job.ends_at},
          "expires_at" => DateTime.add(DateTime.utc_now(), 3 * 86_400, :second)
        })

      {:ok, _view, html} =
        live(conn, ~p"/app/calendar?year=#{job.starts_at.year}&month=#{job.starts_at.month}")

      refute html =~ "Nothing double-booked"
      assert html =~ "Anna and Ben"
      assert html =~ "Pencilled date"
    end

    test "lists a hold that is about to lapse, and releases it", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      hold = hold_fixture(scope, user.id)

      {:ok, view, html} = live(conn, ~p"/app/calendar")
      assert html =~ "Pencilled date"

      html = view |> element("button[phx-value-id='#{hold.id}']") |> render_click()
      assert html =~ "Hold released"

      {:ok, reloaded} = AperDesk.Scoped.fetch(Scheduling.Assignment, scope, hold.id)
      assert reloaded.released_at
    end
  end

  describe "booking a shoot" do
    test "books it through the context and lands back on its month", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/app/calendar/new")

      starts = DateTime.utc_now() |> DateTime.add(7 * 86_400, :second)
      ends = DateTime.add(starts, 4 * 3600, :second)

      view
      |> form("form", job: %{})
      |> render_submit(%{
        "job" => %{
          "title" => "Cliff-top elopement",
          "starts_at" => local_input(starts),
          "ends_at" => local_input(ends),
          "crew_id" => user.id
        }
      })

      assert {:ok, [job]} = Scheduling.list_jobs(scope)
      assert job.title == "Cliff-top elopement"

      # The crew member was reserved in the same transaction.
      assert Scheduling.clashes_for(scope, user.id, {job.starts_at, job.ends_at}) != []
    end

    test "warns while the form is open when the person is already committed", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      job = job_fixture(scope, %{"title" => "Anna and Ben"}, [%{user_id: user.id}])

      {:ok, view, _html} = live(conn, ~p"/app/calendar/new")

      html =
        view
        |> form("form", job: %{})
        |> render_change(%{
          "job" => %{
            "title" => "Overlapping",
            "starts_at" => local_input(job.starts_at),
            "ends_at" => local_input(job.ends_at),
            "crew_id" => user.id
          }
        })

      assert html =~ "Already committed"
      assert html =~ "Anna and Ben"
    end

    test "anchors the typed time to the studio's zone, not the server's", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _studio} = Accounts.update_studio(scope, %{"time_zone" => "Asia/Calcutta"})

      {:ok, view, _html} = live(conn, ~p"/app/calendar/new")

      view
      |> form("form", job: %{})
      |> render_submit(%{
        "job" => %{
          "title" => "Ten in the morning",
          "starts_at" => "2026-11-14T10:00",
          "ends_at" => "2026-11-14T14:00"
        }
      })

      {:ok, [job]} = Scheduling.list_jobs(scope)

      # 10:00 IST is 04:30 UTC. Read as UTC it would have been stored as 10:00,
      # putting the shoot five and a half hours late.
      assert DateTime.to_time(job.starts_at) == ~T[04:30:00.000000]
      assert job.time_zone == "Asia/Calcutta"
    end

    test "keeps the typed time in the field while validating", %{conn: conn, scope: scope} do
      {:ok, _studio} = Accounts.update_studio(scope, %{"time_zone" => "Asia/Calcutta"})

      {:ok, view, _html} = live(conn, ~p"/app/calendar/new")

      html =
        view
        |> form("form", job: %{})
        |> render_change(%{"job" => %{"title" => "Draft", "starts_at" => "2026-11-14T10:00"}})

      # A `datetime-local` input silently empties when handed anything else.
      assert [rendered] =
               Regex.run(~r/name="job\[starts_at\]" value="([^"]*)"/, html,
                 capture: :all_but_first
               )

      assert rendered == "2026-11-14T10:00"
    end

    test "a pristine form does not shout about blank fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/calendar/new")
      refute html =~ "can&#39;t be blank"
    end
  end

  # What a `datetime-local` input actually posts: wall-clock, no zone.
  defp local_input(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> String.slice(0, 16)
  end
end
