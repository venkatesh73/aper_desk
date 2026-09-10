defmodule AperDeskWeb.Graphql.Types.Lead do
  @moduledoc "Leads, the pipeline board, and the mutations that move them."

  use Absinthe.Schema.Notation

  object :lead do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:subtitle, :string)
    field(:email, :string)
    field(:phone, :string)
    field(:shoot_type, :string)
    field(:shoot_date, :string)
    field(:shoot_date_label, :string)
    field(:date_status, :string)
    field(:venue, :string)
    field(:guests, :integer)
    field(:source, :string)
    field(:stage, non_null(:string))
    field(:budget_usd, :float)
    field(:package_summary, :string)
    field(:next_action, :string)
    field(:next_action_tone, :tone)
    field(:assignee, :person)
    field(:hero_image_url, :string)
    field(:readiness, list_of(:readiness_item))
    field(:activity, list_of(:activity_entry))
  end

  object :pipeline_column do
    field(:stage, non_null(:string))
    field(:label, non_null(:string))
    field(:count, non_null(:integer))
    field(:cards, list_of(:pipeline_card))
  end

  object :pipeline_card do
    field(:id, non_null(:id))
    field(:title, non_null(:string))
    field(:meta, :string)
    field(:amount_usd, :float)
    field(:initials, :string)
    field(:badge, :string)
    field(:badge_tone, :tone)
    field(:trailing, :string)
    field(:flag, :string)
  end

  input_object :lead_input do
    field(:name, non_null(:string))
    field(:email, :string)
    field(:phone, :string)
    field(:shoot_type, :shoot_type)
    field(:shoot_date, :string)
    field(:venue, :string)
    field(:guests, :integer)
    field(:budget_usd, :float)
    field(:source, :string)
    field(:assigned_to, :id)
    field(:notes, :string)
  end

  object :lead_payload do
    field(:lead, :lead)
    field(:errors, list_of(:user_error))
  end
end
