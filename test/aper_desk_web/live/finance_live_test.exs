defmodule AperDeskWeb.FinanceLiveTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Finance
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
    %{conn: sign_in(conn, user, studio), scope: scope, user: user, studio: studio}
  end

  defp payout_fixture(scope, user, attrs \\ %{}) do
    Repo.insert!(
      AperDesk.Finance.Payout.changeset(%AperDesk.Finance.Payout{}, %{
        studio_id: AperDesk.Scope.studio_id(scope),
        user_id: user.id,
        description: Map.get(attrs, "description", "Second shooter"),
        amount_cents: Map.get(attrs, "amount_cents", 45_000),
        currency: Map.get(attrs, "currency", "USD"),
        status: Map.get(attrs, "status", "pending")
      })
    )
  end

  describe "the overview" do
    test "says so when there is nothing", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/finance")

      assert html =~ "No invoices yet"
      assert html =~ "Nobody to pay"
      assert html =~ "Nothing overdue"
    end

    test "an overdue invoice is called overdue, not given a date", %{conn: conn, scope: scope} do
      invoice = invoice_fixture(scope, %{"due_on" => Date.add(Date.utc_today(), -12)})
      {:ok, _} = Finance.send_invoice(scope, invoice.id)

      {:ok, _view, html} = live(conn, ~p"/app/finance")

      # "22 Aug" says nothing without today's date in your head.
      assert html =~ "12 days overdue"
    end

    test "outstanding is the sum of what is unpaid", %{conn: conn, scope: scope} do
      one = invoice_fixture(scope)
      two = invoice_fixture(scope)
      {:ok, _} = Finance.send_invoice(scope, one.id)
      {:ok, _} = Finance.send_invoice(scope, two.id)

      {:ok, _view, html} = live(conn, ~p"/app/finance")

      # Two invoices of $2,500 each.
      assert html =~ "$5,000"
    end
  end

  describe "payout runs" do
    test "approves the selection as one run", %{conn: conn, scope: scope, user: user} do
      one = payout_fixture(scope, user)
      two = payout_fixture(scope, user)

      {:ok, view, _html} = live(conn, ~p"/app/finance")

      view |> element("input[phx-value-id='#{one.id}']") |> render_click()
      view |> element("input[phx-value-id='#{two.id}']") |> render_click()
      html = view |> element("button[phx-click='approve-run']") |> render_click()

      assert html =~ "2 approved as one run"

      {:ok, payouts} = Finance.list_payouts(scope, status: "approved")
      assert length(payouts) == 2

      # One run, one id — a Friday payment is a single auditable object.
      assert payouts |> Enum.map(& &1.run_id) |> Enum.uniq() |> length() == 1
    end

    test "a stale selection approves nothing at all", %{conn: conn, scope: scope, user: user} do
      one = payout_fixture(scope, user)
      two = payout_fixture(scope, user)

      {:ok, view, _html} = live(conn, ~p"/app/finance")
      view |> element("input[phx-value-id='#{one.id}']") |> render_click()
      view |> element("input[phx-value-id='#{two.id}']") |> render_click()

      # Somebody else approves one of them first.
      {:ok, _} = Finance.approve_payouts(scope, [two.id])

      html = view |> element("button[phx-click='approve-run']") |> render_click()

      assert html =~ "Nothing was approved"

      # Partially approving would leave crew unpaid with no signal, so the
      # first payout must still be pending.
      {:ok, pending} = Finance.list_payouts(scope, status: "pending")
      assert Enum.map(pending, & &1.id) == [one.id]
    end
  end

  describe "the invoice screen" do
    test "drafts an invoice priced in major units", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/app/finance/invoices/new")

      view |> element("button[phx-click='add-line']") |> render_click()

      view
      |> form("form.form")
      |> render_submit(%{
        "invoice" => %{
          "currency" => "USD",
          "kind" => "deposit",
          "line_items" => %{
            "0" => %{
              "description" => "Deposit",
              "quantity" => "1",
              "unit_price_major" => "1500.25"
            }
          }
        }
      })

      {:ok, [invoice]} = Finance.list_invoices(scope)
      assert invoice.total_cents == 150_025
      assert invoice.status == "draft"
    end

    test "recording a payment moves the balance, not a second counter", %{
      conn: conn,
      scope: scope
    } do
      invoice = invoice_fixture(scope)
      {:ok, invoice} = Finance.send_invoice(scope, invoice.id)

      {:ok, view, _html} = live(conn, ~p"/app/finance/invoices/#{invoice}")

      html =
        view
        |> element("form[phx-submit='record-payment']")
        |> render_submit(%{"payment" => %{"amount_major" => "1000", "method" => "bank_transfer"}})

      assert html =~ "still outstanding"

      {:ok, reloaded} = Finance.fetch_invoice(scope, invoice.id)
      assert reloaded.paid_cents == 100_000
      assert reloaded.status == "partial"
    end

    test "paying the rest closes it", %{conn: conn, scope: scope} do
      invoice = invoice_fixture(scope)
      {:ok, invoice} = Finance.send_invoice(scope, invoice.id)

      {:ok, view, _html} = live(conn, ~p"/app/finance/invoices/#{invoice}")

      # The amount field starts at what is left, so the common case is one tap.
      html =
        view
        |> element("form[phx-submit='record-payment']")
        |> render_submit(%{"payment" => %{"amount_major" => "2500", "method" => "bank_transfer"}})

      assert html =~ "Paid in full"

      {:ok, reloaded} = Finance.fetch_invoice(scope, invoice.id)
      assert reloaded.status == "paid"
    end

    test "an issued invoice cannot be re-priced", %{conn: conn, scope: scope} do
      invoice = invoice_fixture(scope)
      {:ok, invoice} = Finance.send_invoice(scope, invoice.id)

      {:ok, _view, html} = live(conn, ~p"/app/finance/invoices/#{invoice}")

      assert html =~ "cannot be re-priced"
      refute html =~ "Save the invoice"
    end
  end
end
