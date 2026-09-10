defmodule AperDeskWeb.Graphql.Types.Team do
  @moduledoc "People: who is on the books, who is away, who is being onboarded."

  use Absinthe.Schema.Notation

  object :team do
    field(:staff_count, :integer)
    field(:freelancer_count, :integer)
    field(:members, list_of(:team_member))
    field(:leave_requests, list_of(:leave_request))
    field(:roster, list_of(:roster_row))
    field(:contracts, list_of(:contract_row))
    field(:onboarding, list_of(:onboarding_row))
  end

  object :team_member do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:role, :string)
    field(:avatar_url, :string)
    field(:tags, list_of(:chip))
  end

  object :leave_request do
    field(:id, non_null(:id))
    field(:person, :string)
    field(:dates, :string)
    field(:reason, :string)
    field(:detail, :string)
    field(:tone, :tone)
  end

  object :roster_row do
    field(:person, :string)
    field(:days, list_of(:roster_day))
  end

  object :roster_day do
    field(:label, :string)
    field(:kind, :string)
  end

  object :contract_row do
    field(:person, :string)
    field(:detail, :string)
    field(:trailing, :string)
    field(:tone, :tone)
  end

  object :onboarding_row do
    field(:person, :string)
    field(:day_label, :string)
    field(:tasks, list_of(:onboarding_task))
  end

  object :onboarding_task do
    field(:label, non_null(:string))
    field(:done, :boolean)
  end
end
