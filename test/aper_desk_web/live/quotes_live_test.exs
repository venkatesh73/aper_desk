defmodule AperDeskWeb.QuotesLiveTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Sales

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

  defp quote_fixture(scope, attrs \\ %{}) do
    {:ok, quote} =
      Sales.create_quote(
        scope,
        Map.merge(%{"title" => "Anna and Ben", "currency" => "USD"}, attrs)
      )

    quote
  end

  describe "the list" do
    test "says so when there is nothing", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/quotes")
      assert html =~ "No quotes yet"
    end

    test "a draft says it has not gone out", %{conn: conn, scope: scope} do
      quote_fixture(scope, %{"title" => "Cliff-top elopement"})

      {:ok, _view, html} = live(conn, ~p"/app/quotes")

      assert html =~ "Cliff-top elopement"
      assert html =~ "Not sent yet"
      assert html =~ "Draft"
    end

    test "the status filter narrows the list", %{conn: conn, scope: scope} do
      quote_fixture(scope, %{"title" => "Still a draft"})
      sent = quote_fixture(scope, %{"title" => "Already out"})
      {:ok, _, _token} = Sales.send_quote(scope, sent.id)

      {:ok, view, _html} = live(conn, ~p"/app/quotes")

      html = view |> element("button[phx-value-status='sent']") |> render_click()
      assert html =~ "Already out"
      refute html =~ "Still a draft"
    end
  end

  describe "the editor" do
    test "a line item is priced in major units and stored in minor", %{
      conn: conn,
      scope: scope
    } do
      quote = quote_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/app/quotes/#{quote}")

      view |> element("button[phx-click='add-line']") |> render_click()

      view
      |> form("form")
      |> render_submit(%{
        "quote" => %{
          "title" => "Anna and Ben",
          "currency" => "USD",
          "deposit_major" => "1500",
          "line_items" => %{
            "0" => %{
              "description" => "Ten hours of coverage",
              "quantity" => "1",
              "unit_price_major" => "4500.10",
              "position" => "0"
            }
          }
        }
      })

      {:ok, saved} = Sales.fetch_quote(scope, quote.id)
      assert [line] = saved.line_items
      assert line.description == "Ten hours of coverage"

      # 4500.10 * 100 is 450009.99999999994 as a float. One cent of silent
      # error per line is exactly what Money.from_major/2 exists to prevent.
      assert line.unit_price_cents == 450_010
      assert saved.subtotal_cents == 450_010
      assert saved.total_cents == 450_010
      assert saved.deposit_cents == 150_000
    end

    test "the total is derived from the lines, never from the form", %{
      conn: conn,
      scope: scope
    } do
      quote = quote_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/app/quotes/#{quote}")

      view
      |> form("form")
      |> render_submit(%{
        "quote" => %{
          "title" => "Anna and Ben",
          "currency" => "USD",
          "discount_major" => "500",
          "tax_major" => "230",
          "total_cents" => "1",
          "subtotal_cents" => "1",
          "line_items" => %{
            "0" => %{
              "description" => "Coverage",
              "quantity" => "2",
              "unit_price_major" => "1000",
              "position" => "0"
            }
          }
        }
      })

      {:ok, saved} = Sales.fetch_quote(scope, quote.id)
      assert saved.subtotal_cents == 200_000
      assert saved.total_cents == 200_000 - 50_000 + 23_000
    end

    test "removing a line keeps the rest", %{conn: conn, scope: scope} do
      quote = quote_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/app/quotes/#{quote}")

      view
      |> form("form")
      |> render_submit(%{
        "quote" => %{
          "title" => "Anna and Ben",
          "currency" => "USD",
          "line_items" => %{
            "0" => %{
              "description" => "First",
              "quantity" => "1",
              "unit_price_major" => "100",
              "position" => "0"
            },
            "1" => %{
              "description" => "Second",
              "quantity" => "1",
              "unit_price_major" => "200",
              "position" => "1"
            },
            "2" => %{
              "description" => "Third",
              "quantity" => "1",
              "unit_price_major" => "300",
              "position" => "2"
            }
          }
        }
      })

      {:ok, view, _html} = live(conn, ~p"/app/quotes/#{quote}")
      view |> element("button[phx-value-index='1']") |> render_click()
      view |> form("form") |> render_submit()

      {:ok, saved} = Sales.fetch_quote(scope, quote.id)
      descriptions = saved.line_items |> Enum.sort_by(& &1.position) |> Enum.map(& &1.description)

      # Re-keyed from zero on removal: a gap in the indices silently drops
      # every line after it.
      assert descriptions == ["First", "Third"]
    end

    test "an accepted quote cannot be re-priced", %{conn: conn, scope: scope} do
      quote = quote_fixture(scope)
      {:ok, _, _token} = Sales.send_quote(scope, quote.id)
      {:ok, _} = Sales.accept_quote(scope, quote.id)

      {:ok, _view, html} = live(conn, ~p"/app/quotes/#{quote}")

      assert html =~ "cannot be re-priced"
      refute html =~ "Save the quote"
    end
  end

  describe "sending" do
    test "shows the link once and opens as the client", %{conn: conn, scope: scope} do
      quote = quote_fixture(scope, %{"title" => "Anna and Ben"})
      {:ok, view, _html} = live(conn, ~p"/app/quotes/#{quote}")

      html = view |> element("button[phx-click='send']") |> render_click()
      assert [url] = Regex.run(~r{https?://[^"]+/q/[A-Za-z0-9_-]+}, html)

      token = url |> String.split("/q/") |> List.last()

      {:ok, _client, client_html} = live(build_conn(), ~p"/q/#{token}")
      assert client_html =~ "Anna and Ben"

      # Opening it is what tells the studio the client has read it.
      {:ok, reloaded} = Sales.fetch_quote(scope, quote.id)
      assert reloaded.status == "viewed"
      assert reloaded.view_count == 1
      assert reloaded.first_viewed_at
    end

    test "a draft has no link to open", %{scope: scope} do
      quote = quote_fixture(scope)
      {:ok, _, token} = Sales.send_quote(scope, quote.id)

      # Back to draft: the token still hashes to this row, but a quote that is
      # not out should not be readable through it. Re-read first — changing a
      # stale struct produces no changes at all, and Ecto skips the update.
      AperDesk.Sales.Quote
      |> AperDesk.Repo.get!(quote.id)
      |> Ecto.Changeset.change(status: "draft")
      |> AperDesk.Repo.update!()

      {:ok, _view, html} = live(build_conn(), ~p"/q/#{token}")
      assert html =~ "does not open anything"
    end

    test "a made-up token gets the same page", %{} do
      {:ok, _view, html} = live(build_conn(), ~p"/q/#{"nonsense"}")
      assert html =~ "does not open anything"
    end
  end
end
