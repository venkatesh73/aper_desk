defmodule AperDeskWeb.Graphql.Types.Calendar do
  @moduledoc "The month view, plus the clashes and holds it surfaces."

  use Absinthe.Schema.Notation

  object :calendar do
    field(:days, list_of(:calendar_day))
    field(:clashes, list_of(:calendar_clash))
    field(:holds_expiring, list_of(:hold_expiring))
    field(:travel, list_of(:travel_note))
  end

  object :calendar_day do
    field(:day, non_null(:integer))
    field(:events, list_of(:calendar_event))
  end

  object :calendar_event do
    field(:label, non_null(:string))
    field(:kind, non_null(:string))
  end

  @desc "Two commitments that overlap for one person."
  object :calendar_clash do
    field(:id, non_null(:id))
    field(:date, :string)
    field(:shooter, :string)
    field(:detail, :string)
    field(:actions, list_of(:string))
  end

  @desc "A soft hold that is about to lapse."
  object :hold_expiring do
    field(:label, non_null(:string))
    field(:trailing, :string)
  end

  object :travel_note do
    field(:label, non_null(:string))
    field(:detail, :string)
  end
end
