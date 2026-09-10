defmodule AperDeskWeb.Graphql.Types.Dashboard do
  @moduledoc "The role-specific home screen."

  use Absinthe.Schema.Notation

  object :dashboard do
    field(:greeting, :string)
    field(:subtitle, :string)
    field(:stats, list_of(:stat))
    field(:bookings_by_month, list_of(:bookings_month))
    field(:needs_attention, list_of(:attention_item))
    field(:upcoming_shoots, list_of(:upcoming_shoot))
    field(:leads_by_source, list_of(:leads_source))
  end

  object :bookings_month do
    field(:month, non_null(:string))
    field(:count, non_null(:integer))
    field(:past, :boolean)
  end

  object :attention_item do
    field(:title, non_null(:string))
    field(:subtitle, :string)
    field(:trailing, :string)
    field(:tone, :tone)
  end

  object :upcoming_shoot do
    field(:id, non_null(:id))
    field(:title, non_null(:string))
    field(:when, :string)
    field(:where, :string)
    field(:image_url, :string)
  end

  object :leads_source do
    field(:source, non_null(:string))
    field(:count, non_null(:integer))
    field(:booked_rate, :float)
  end
end
