defmodule AperDeskWeb.Graphql.Resolvers.StudioResolver do
  @moduledoc "Resolves the caller's studio and the storage meter on its header."

  alias AperDesk.Billing
  alias AperDesk.Billing.{Plan, StudioUsage}
  alias AperDesk.Money
  alias AperDesk.Repo
  alias AperDesk.Scope
  alias AperDeskWeb.Graphql.Resolvers.Helpers

  def current_studio(_parent, _args, %{context: %{scope: %Scope{studio: nil}}}),
    do: {:error, :unauthorized}

  def current_studio(_parent, _args, %{context: %{scope: scope}}) do
    studio = scope.studio
    usage = Repo.get(StudioUsage, studio.id) || %StudioUsage{}
    subscription = Billing.get_subscription(scope)

    {:ok,
     %{
       id: studio.id,
       name: studio.name,
       base_city: studio.city,
       plan: subscription && subscription.plan.name,
       # Stored in minutes because the SLA is measured in minutes; the client
       # shows hours, so the conversion happens once, here.
       reply_sla_hours: div(studio.reply_sla_minutes || 240, 60),
       hold_length_days: 7,
       reporting_currency: studio.base_currency,
       client_currencies: Money.supported_currencies(),
       default_tax: 0.0,
       storage_used_gb: Helpers.to_gb(usage.live_bytes),
       storage_limit_gb: storage_limit_gb(subscription),
       current_user: scope.user
     }}
  end

  defp storage_limit_gb(nil), do: 0.0

  defp storage_limit_gb(subscription) do
    case Plan.limit(subscription.plan, "storage_bytes") do
      :unlimited -> 0.0
      bytes -> Helpers.to_gb(bytes)
    end
  end
end
