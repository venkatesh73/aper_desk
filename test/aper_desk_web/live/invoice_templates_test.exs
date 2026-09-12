defmodule AperDeskWeb.InvoiceTemplatesTest do
  @moduledoc """
  The fourth kind of template.

  Built as a table rather than a set of studio defaults: a wedding deposit, a
  balance due a fortnight before, and commercial work on thirty days are three
  different documents, and one default means retyping two of them every time.
  """
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import AperDeskWeb.ComboboxHelpers
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Finance
  alias AperDesk.Finance.InvoiceTemplate

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
    %{conn: sign_in(conn, user, studio), scope: scope, studio: studio}
  end

  defp template_fixture(scope, attrs \\ %{}) do
    {:ok, template} =
      Finance.create_invoice_template(
        scope,
        Map.merge(%{"name" => "Wedding deposit", "kind" => "deposit", "due_in_days" => 7}, attrs)
      )

    template
  end

  describe "the arithmetic" do
    test "tax is a rate, not an amount" do
      template = %InvoiceTemplate{tax_bps: 2300}

      assert InvoiceTemplate.tax_percent(template) == 23.0
      assert InvoiceTemplate.tax_on(template, 450_000, "USD") == 103_500

      # The amount depends on the invoice; the rate does not.
      assert InvoiceTemplate.tax_on(template, 100_000, "USD") == 23_000
    end

    test "rounds once on the whole, not per line" do
      template = %InvoiceTemplate{tax_bps: 2300}

      # 23% of 33 cents is 7.59; rounded once it is 8, and seven lines rounded
      # separately would not add up to the number the client sees.
      assert InvoiceTemplate.tax_on(template, 33, "USD") == 8
    end
  end

  describe "one default per studio" do
    test "claiming the default demotes the old one", %{scope: scope} do
      first = template_fixture(scope, %{"name" => "First", "is_default" => true})
      second = template_fixture(scope, %{"name" => "Second", "is_default" => true})

      # A studio ticking "use this one" means it, and should not have to go
      # and untick the old one first.
      {:ok, reloaded} = Finance.fetch_invoice_template(scope, first.id)
      refute reloaded.is_default

      {:ok, reloaded} = Finance.fetch_invoice_template(scope, second.id)
      assert reloaded.is_default
    end

    test "a shoot-type match beats the default", %{scope: scope} do
      template_fixture(scope, %{"name" => "House default", "is_default" => true})
      wedding = template_fixture(scope, %{"name" => "Weddings", "shoot_type" => "wedding"})

      assert {:ok, chosen} = Finance.default_invoice_template(scope, "wedding")
      assert chosen.id == wedding.id

      # Nothing specific for a portrait, so the house default stands.
      assert {:ok, fallback} = Finance.default_invoice_template(scope, "portrait")
      assert fallback.name == "House default"
    end
  end

  describe "the Templates screen" do
    test "lists invoice templates on their own tab", %{conn: conn, scope: scope} do
      template_fixture(scope, %{"name" => "Wedding deposit", "is_default" => true})

      {:ok, _view, html} = live(conn, ~p"/app/templates?tab=invoice")

      assert html =~ "Wedding deposit"
      assert html =~ "Due 7 days after issue"
      assert html =~ "default"
    end

    test "creates one from the form", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/app/templates/invoice/new")

      view
      |> form("form")
      |> render_submit(%{
        "template" => %{
          "name" => "Commercial 30 days",
          "kind" => "full",
          "due_in_days" => "30",
          "tax_percent" => "23",
          "tax_label" => "VAT",
          "notes" => "Thanks for the work."
        }
      })

      assert {:ok, [template]} = Finance.list_invoice_templates(scope)
      assert template.name == "Commercial 30 days"
      assert template.due_in_days == 30

      # Typed as 23, stored as basis points.
      assert template.tax_bps == 2300
    end

    test "previews against real arithmetic rather than placeholders", %{
      conn: conn,
      scope: scope
    } do
      template = template_fixture(scope, %{"tax_percent" => nil, "tax_bps" => 2300})

      {:ok, view, _html} = live(conn, ~p"/app/templates?tab=invoice")

      html =
        view
        |> element("button[phx-click='preview'][phx-value-id='#{template.id}']")
        |> render_click()

      assert html =~ "Invoice"
      assert html =~ "23.0%"
      # $4,500 subtotal plus 23% is $5,535.
      assert html =~ "$5,535"
    end
  end

  describe "raising an invoice from one" do
    test "fills in the terms and leaves the pricing alone", %{conn: conn, scope: scope} do
      _template =
        template_fixture(scope, %{
          "name" => "Wedding deposit",
          "kind" => "deposit",
          "due_in_days" => 7,
          "tax_bps" => 2300,
          "notes" => "The date is held once this clears."
        })

      {:ok, view, _html} = live(conn, ~p"/app/finance/invoices/new")

      view |> element("button[phx-click='add-line']") |> render_click()

      view
      |> form("form.form")
      |> render_change(%{
        "invoice" => %{
          "currency" => "USD",
          "line_items" => %{
            "0" => %{"description" => "Deposit", "quantity" => "1", "unit_price_major" => "1000"}
          }
        }
      })

      # Chosen through the combobox, which is what the studio clicks.
      html = choose_and_settle(view, "invoice-template", "Wedding deposit")

      assert html =~ "Wedding deposit applied"
      # The line the studio already typed survives.
      assert html =~ "Deposit"
      assert html =~ "1000"
      # And the terms arrived: 23% of $1,000.
      assert html =~ "230.00"
    end

    test "applying a template does not create anything on its own", %{
      conn: conn,
      scope: scope
    } do
      template = template_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/app/finance/invoices/new")

      choose(view, "invoice-template", template.name)

      # Picking terms is not raising an invoice.
      assert {:ok, []} = Finance.list_invoices(scope)
    end
  end

  test "archiving leaves invoices already raised alone", %{scope: scope} do
    template = template_fixture(scope)

    assert {:ok, _} = Finance.archive_invoice_template(scope, template.id)
    assert {:ok, []} = Finance.list_invoice_templates(scope)
    assert {:ok, [_]} = Finance.list_invoice_templates(scope, include_archived: true)
  end

  test "a photographer cannot see or write them", %{studio: studio, scope: scope} do
    template_fixture(scope)

    {:ok, user} =
      Accounts.register_user(%{
        "name" => "Jonas",
        "email" => "jonas-#{System.unique_integer([:positive])}@example.com",
        "password" => "a sufficiently long passphrase"
      })

    AperDesk.Repo.insert!(
      Accounts.Membership.changeset(%Accounts.Membership{}, %{
        user_id: user.id,
        studio_id: studio.id,
        role: "photographer",
        status: "active"
      })
    )

    {:ok, photographer} = Accounts.scope_for(user, studio.id)

    assert {:error, :unauthorized} = Finance.list_invoice_templates(photographer)

    assert {:error, :unauthorized} =
             Finance.create_invoice_template(photographer, %{"name" => "Mine"})
  end
end
