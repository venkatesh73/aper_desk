defmodule AperDeskWeb.Graphql.Types.Finance do
  @moduledoc "The money screen: invoices out, payouts owed, FX exposure."

  use Absinthe.Schema.Notation

  object :finance do
    field(:stats, list_of(:stat))
    field(:invoices, list_of(:invoice_row))
    field(:payouts, list_of(:payout_row))
    field(:fx_exposure, list_of(:fx_exposure))
  end

  object :invoice_row do
    field(:id, non_null(:id))
    field(:reference, :string)
    field(:client, :string)
    field(:due, :string)
    field(:status, :string)
    field(:status_tone, :tone)
    field(:amount_usd, :float)
  end

  object :payout_row do
    field(:id, non_null(:id))
    field(:reference, :string)
    field(:person, :string)
    field(:shoot, :string)
    field(:status, :string)
    field(:status_tone, :tone)
    field(:amount_usd, :float)
  end

  @desc "Share of outstanding money held in each currency."
  object :fx_exposure do
    field(:currency, non_null(:string))
    field(:percent, :float)
  end
end
