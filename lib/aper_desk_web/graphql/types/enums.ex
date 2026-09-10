defmodule AperDeskWeb.Graphql.Types.Enums do
  @moduledoc """
  Enums shared across the schema.

  Values mirror the string values stored in the database, so a stage is one
  concept from Postgres check constraint through to the mobile client rather
  than three overlapping vocabularies that have to be mapped at each boundary.
  """

  use Absinthe.Schema.Notation

  enum :lead_stage do
    value(:new, as: "new")
    value(:contacted, as: "contacted")
    value(:consult, as: "consult")
    value(:quote_sent, as: "quote_sent")
    value(:booked, as: "booked")
    value(:completed, as: "completed")
    value(:lost, as: "lost")
  end

  enum :shoot_type do
    value(:wedding, as: "wedding")
    value(:portrait, as: "portrait")
    value(:newborn, as: "newborn")
    value(:family, as: "family")
    value(:engagement, as: "engagement")
    value(:event, as: "event")
    value(:commercial, as: "commercial")
    value(:product, as: "product")
    value(:real_estate, as: "real_estate")
    value(:other, as: "other")
  end

  enum :studio_role do
    value(:owner, as: "owner")
    value(:photographer, as: "photographer")
    value(:finance, as: "finance")
    value(:hr, as: "hr")
    value(:ops, as: "ops")
  end

  enum :gallery_status do
    value(:draft, as: "draft")
    value(:ready, as: "ready")
    value(:delivered, as: "delivered")
    value(:archived, as: "archived")
    value(:purged, as: "purged")
  end

  enum :automation_mode do
    value(:auto, as: "auto")
    value(:ask, as: "ask")
  end

  @desc "A visual weight the client renders as a colour."
  enum :tone do
    value(:neutral)
    value(:positive)
    value(:warning)
    value(:critical)
    value(:info)
  end
end
