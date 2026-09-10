defmodule AperDeskWeb.Graphql.Types.Plan do
  @moduledoc "The public pricing table."

  use Absinthe.Schema.Notation

  object :plan do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:eyebrow, :string)
    field(:monthly_price_usd, :float)
    field(:for_whom, :string)
    field(:features, list_of(:string))
    field(:highlighted, :boolean)
  end

  object :plan_comparison do
    field(:groups, list_of(:plan_comparison_group))
  end

  object :plan_comparison_group do
    field(:title, non_null(:string))
    field(:rows, list_of(:plan_comparison_row))
  end

  object :plan_comparison_row do
    field(:label, non_null(:string))
    field(:solo, :string)
    field(:studio, :string)
    field(:agency, :string)
  end
end
