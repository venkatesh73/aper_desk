defmodule AperDeskWeb.Graphql.Types.Automation do
  @moduledoc "Workflows as the client sees them: a name, a mode, and a switch."

  use Absinthe.Schema.Notation

  object :automation do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:description, :string)

    @desc "`ask` holds each step for approval; `auto` runs it unattended."
    field(:mode, :string)

    field(:enabled, :boolean)
  end

  object :automation_payload do
    field(:automation, :automation)
    field(:errors, list_of(:user_error))
  end
end
