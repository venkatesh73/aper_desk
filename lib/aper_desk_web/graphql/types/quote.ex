defmodule AperDeskWeb.Graphql.Types.Quote do
  @moduledoc "Quotes, their line items, and what the studio actually keeps."

  use Absinthe.Schema.Notation

  object :quote do
    field(:id, non_null(:id))
    field(:reference, :string)
    field(:client_name, :string)
    field(:client_email, :string)
    field(:shoot_date_label, :string)
    field(:client_currency, :string)
    field(:status, :string)
    field(:package_options, list_of(:package_option))
    field(:package_note, :string)
    field(:line_items, list_of(:quote_line))
    field(:crew, list_of(:crew_cost))
    field(:terms, :quote_terms)
    field(:totals, :quote_totals)
    field(:readiness, list_of(:readiness_item))
  end

  object :package_option do
    field(:id, non_null(:id))
    field(:label, non_null(:string))
    field(:selected, :boolean)
  end

  object :quote_line do
    field(:id, non_null(:id))
    field(:label, non_null(:string))
    field(:qty, :float)
    field(:amount_usd, :float)
  end

  object :crew_cost do
    field(:name, non_null(:string))
    field(:role, :string)
    field(:payout_usd, :float)
  end

  object :quote_terms do
    field(:deposit, :string)
    field(:balance_due, :string)
    field(:expires_on, :string)
    field(:notes, :string)
  end

  @desc """
  The money view of a quote.

  `margin_percent` is what the studio keeps after crew payouts — the number that
  decides whether a booking is worth taking, and the one a line-item list alone
  does not show.
  """
  object :quote_totals do
    field(:subtotal_usd, :float)
    field(:discount_usd, :float)
    field(:discount_label, :string)
    field(:tax_usd, :float)
    field(:tax_label, :string)
    field(:client_pays_usd, :float)
    field(:deposit_usd, :float)
    field(:crew_cost_usd, :float)
    field(:margin_percent, :float)
  end

  object :quote_summary do
    field(:id, non_null(:id))
    field(:reference, :string)
    field(:client_name, :string)
  end

  object :quote_payload do
    field(:quote, :quote)
    field(:errors, list_of(:user_error))
  end
end
