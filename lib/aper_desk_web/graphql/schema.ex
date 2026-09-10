defmodule AperDeskWeb.Graphql.Schema do
  @moduledoc """
  The GraphQL API the mobile client speaks.

  Two things are enforced schema-wide rather than per resolver:

    * **Every studio-scoped field requires a scope.** `RequireScope` is applied
      as middleware to each such field, so a new query cannot accidentally ship
      without an auth check. Public fields — the pricing table — are the
      explicit exception.
    * **Errors are translated once.** `HandleErrors` turns the tagged tuples
      contexts return into a message plus a stable `code`, so the client
      branches on the code rather than parsing prose.

  Complexity and depth limits are configured in `config/config.exs` and applied
  in the router: a public GraphQL endpoint without them is a denial-of-service
  waiting for a deeply nested query.
  """

  use Absinthe.Schema

  alias AperDeskWeb.Graphql.Middleware
  alias AperDeskWeb.Graphql.Resolvers

  import_types(AperDeskWeb.Graphql.Types.Enums)
  import_types(AperDeskWeb.Graphql.Types.Common)
  import_types(AperDeskWeb.Graphql.Types.Studio)
  import_types(AperDeskWeb.Graphql.Types.Lead)
  import_types(AperDeskWeb.Graphql.Types.Dashboard)
  import_types(AperDeskWeb.Graphql.Types.Calendar)
  import_types(AperDeskWeb.Graphql.Types.Gallery)
  import_types(AperDeskWeb.Graphql.Types.Quote)
  import_types(AperDeskWeb.Graphql.Types.Finance)
  import_types(AperDeskWeb.Graphql.Types.Team)
  import_types(AperDeskWeb.Graphql.Types.Automation)
  import_types(AperDeskWeb.Graphql.Types.Plan)

  query do
    @desc "The studio the caller is acting in."
    field :current_studio, :studio do
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.StudioResolver.current_studio/3)
    end

    @desc "Leads, optionally filtered."
    field :leads, list_of(:lead) do
      arg(:stage, :lead_stage)
      arg(:type, :shoot_type)
      arg(:assigned_to, :id)
      arg(:search, :string)
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.LeadResolver.list/3)
    end

    field :lead, :lead do
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.LeadResolver.get/3)
    end

    @desc "The pipeline board, one column per stage."
    field :pipeline, list_of(:pipeline_column) do
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.LeadResolver.pipeline/3)
    end

    @desc "The home screen, assembled for one role."
    field :dashboard, :dashboard do
      arg(:role, non_null(:studio_role))
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.DashboardResolver.dashboard/3)
    end

    field :calendar, :calendar do
      arg(:month, non_null(:integer))
      arg(:year, non_null(:integer))
      arg(:shooter_id, :id)
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.MiscResolver.calendar/3)
    end

    field :galleries, list_of(:gallery_summary) do
      arg(:status, :gallery_status)
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.GalleryResolver.list/3)
    end

    field :gallery, :gallery do
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.GalleryResolver.get/3)
    end

    field :quote, :quote do
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.QuoteResolver.get/3)
    end

    field :open_quotes, list_of(:quote_summary) do
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.QuoteResolver.open_quotes/3)
    end

    field :finance, :finance do
      arg(:month, non_null(:integer))
      arg(:year, non_null(:integer))
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.MiscResolver.finance/3)
    end

    field :team, :team do
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.MiscResolver.team/3)
    end

    field :automations, list_of(:automation) do
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.MiscResolver.automations/3)
    end

    @desc "The public pricing table. Deliberately available without a scope."
    field :plans, list_of(:plan) do
      resolve(&Resolvers.MiscResolver.plans/3)
    end

    field :plan_comparison, :plan_comparison do
      resolve(&Resolvers.MiscResolver.plan_comparison/3)
    end
  end

  mutation do
    field :create_lead, :lead_payload do
      arg(:input, non_null(:lead_input))
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.LeadResolver.create/3)
    end

    field :update_lead_stage, :lead_payload do
      arg(:id, non_null(:id))
      arg(:stage, non_null(:lead_stage))
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.LeadResolver.update_stage/3)
    end

    field :send_quote, :quote_payload do
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.QuoteResolver.send_quote/3)
    end

    field :update_automation, :automation_payload do
      arg(:id, non_null(:id))
      arg(:mode, :automation_mode)
      arg(:enabled, :boolean)
      middleware(Middleware.RequireScope)
      resolve(&Resolvers.MiscResolver.update_automation/3)
    end
  end

  @doc """
  Append error translation to every field.

  Done here rather than per resolver so a new field cannot ship returning a raw
  tagged tuple the client has to guess at.
  """
  def middleware(middleware, _field, %{identifier: type})
      when type in [:query, :mutation, :subscription] do
    middleware ++ [Middleware.HandleErrors]
  end

  def middleware(middleware, _field, _object), do: middleware
end
