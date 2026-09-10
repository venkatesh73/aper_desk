defmodule AperDeskWeb.Graphql.Types.Studio do
  @moduledoc "The studio the caller is acting in, and who they are."

  use Absinthe.Schema.Notation

  object :studio do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:base_city, :string)
    field(:plan, :string)
    field(:reply_sla_hours, :integer)
    field(:hold_length_days, :integer)
    field(:reporting_currency, :string)
    field(:client_currencies, list_of(:string))
    field(:default_tax, :float)
    field(:storage_used_gb, :float)
    field(:storage_limit_gb, :float)
    field(:current_user, :person)
  end
end
