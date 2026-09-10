defmodule AperDeskWeb.LandingLiveTest do
  @moduledoc """
  The landing page renders prices from the same `Plan` rows the product bills
  against, so these tests guard the thing that actually matters: the page cannot
  quote a number the billing system would not charge.
  """

  use AperDeskWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AperDesk.Billing.Plan
  alias AperDesk.Finance.FxRate
  alias AperDesk.Repo

  setup do
    gb = 1_073_741_824

    solo =
      Repo.insert!(
        Plan.changeset(%Plan{}, %{
          key: "solo",
          name: "Solo",
          tagline: "For the solo photographer.",
          monthly_price_cents: 1500,
          yearly_price_cents: 16_200,
          currency: "USD",
          position: 1,
          limits: %{"seats" => 1, "active_leads" => 50, "storage_bytes" => 10 * gb}
        })
      )

    studio =
      Repo.insert!(
        Plan.changeset(%Plan{}, %{
          key: "studio",
          name: "Studio",
          tagline: "For the working photographer.",
          monthly_price_cents: 2400,
          yearly_price_cents: 25_920,
          extra_seat_price_cents: 350,
          currency: "USD",
          position: 2,
          limits: %{"seats" => 3, "storage_bytes" => 100 * gb}
        })
      )

    %{solo: solo, studio: studio}
  end

  describe "rendering" do
    test "shows the marketing sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Every inquiry answered"
      assert html =~ "Built for how a studio actually runs."
      assert html =~ "From inquiry to delivery, in four phases."
      assert html =~ "One studio, five seats at the table."
      assert html =~ "Simple, predictable pricing."
      assert html =~ "Frequently asked questions."
    end

    test "uses the studio logo, not the Phoenix scaffold one", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "logo-long.png"
      refute html =~ "logo.svg", "logo.svg is the Phoenix scaffold mark, not AperDesk's"
    end

    test "prices come from the plan rows", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "$15"
      assert html =~ "$24"
      assert html =~ "For the solo photographer."
    end

    test "plan bullets are generated from the limits map", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "1 user"
      assert html =~ "50 active leads"
      assert html =~ "10 GB live storage"
      assert html =~ "3 users"
      assert html =~ "100 GB live storage"
    end
  end

  describe "billing period" do
    test "yearly shows the monthly equivalent, to the cent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("button[phx-value-period=yearly]") |> render_click()

      # 16_200 / 12 = 1350 cents. Rendering this as "$13" would understate the
      # price on the one page where that must not happen.
      assert html =~ "$13.50"
      assert html =~ "$21.60"
    end

    test "the yearly label states the real saving", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Yearly · save 10%"
    end
  end

  describe "currency" do
    test "a currency with no rate is not offered", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(phx-value-currency="USD")

      refute html =~ ~s(phx-value-currency="EUR"),
             "offering a currency with no FX rate renders a USD amount with a euro sign"
    end

    test "a currency with a rate is offered and converts", %{conn: conn} do
      Repo.insert!(
        FxRate.changeset(%FxRate{}, %{
          base_currency: "USD",
          quote_currency: "EUR",
          rate: Decimal.new("0.92"),
          as_of: Date.utc_today()
        })
      )

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ ~s(phx-value-currency="EUR")

      converted = view |> element("button[phx-value-currency=EUR]") |> render_click()

      # 1500 cents at 0.92 = 1380 cents.
      assert converted =~ "€13.80"
      refute converted =~ "€15", "the price was relabelled rather than converted"
    end
  end
end
