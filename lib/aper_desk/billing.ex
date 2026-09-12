defmodule AperDesk.Billing do
  @moduledoc """
  Plans, subscriptions, add-ons and Stripe webhooks.

  Webhook handling is the part that has to be right. Stripe delivers
  at-least-once and out of order, so `handle_webhook/3` records the provider's
  event id and applies the change in a single transaction: if the insert
  collides with the unique index, the whole thing rolls back and the redelivery
  is reported as already processed. There is no window in which the event is
  marked handled but the change did not land, or vice versa.

  Out-of-order delivery is handled separately, by ignoring updates that carry a
  period start older than the one already stored — otherwise a late-arriving
  `subscription.updated` could revert a plan change that superseded it.
  """

  import Ecto.Query

  alias AperDesk.Authorization
  alias AperDesk.Billing.{Limits, Plan, ProcessedWebhookEvent, Subscription, SubscriptionAddOn}
  alias AperDesk.Repo
  alias AperDesk.Scope
  alias Ecto.Multi

  ## Plans

  @doc "Publicly listed plans, newest version of each."
  def list_public_plans do
    Repo.all(
      from p in Plan,
        where: p.public,
        distinct: p.key,
        order_by: [asc: p.key, desc: p.version]
    )
    |> Enum.sort_by(& &1.position)
  end

  @doc """
  The current version of a plan.

  Always the newest — but subscriptions store the specific `plan_id` they were
  sold, so publishing a new version never re-prices anyone already on it.
  """
  def current_plan(key) do
    Repo.one(from p in Plan, where: p.key == ^key, order_by: [desc: p.version], limit: 1)
  end

  def create_plan(attrs), do: %Plan{} |> Plan.changeset(attrs) |> Repo.insert()

  @doc """
  Publish a new version of a plan.

  A price change is an insert, never an update — an update would silently
  restate what existing customers agreed to pay.
  """
  def publish_plan_version(key, attrs) do
    case current_plan(key) do
      nil ->
        {:error, :not_found}

      plan ->
        %Plan{}
        |> Plan.changeset(
          plan
          |> Map.take([
            :key,
            :name,
            :tagline,
            :monthly_price_cents,
            :yearly_price_cents,
            :currency,
            :extra_seat_price_cents,
            :limits,
            :features,
            :position,
            :public
          ])
          |> Map.merge(Map.new(attrs, fn {k, v} -> {to_atom(k), v} end))
          |> Map.put(:version, plan.version + 1)
        )
        |> Repo.insert()
    end
  end

  ## Subscriptions

  def get_subscription(%Scope{} = scope) do
    Repo.one(
      from s in Subscription,
        where: s.studio_id == ^Scope.studio_id(scope),
        preload: [:plan, :add_ons]
    )
  end

  @doc "Put a new studio on its free trial."
  def start_trial(%Scope{} = scope, plan_key \\ nil) do
    with :ok <- Authorization.authorize(scope, :"billing.write"),
         %Plan{} = plan <- trial_plan(plan_key) do
      %Subscription{}
      |> Subscription.changeset(%{
        studio_id: Scope.studio_id(scope),
        plan_id: plan.id,
        status: "trialing",
        billing_period: "monthly"
      })
      |> Subscription.trial_changeset(plan.id)
      |> Repo.insert()
    else
      nil -> {:error, :plan_not_found}
      error -> error
    end
  end

  # The entry plan, by position, rather than a hardcoded key. The default used
  # to be `"basic"`, which exists in no seed file and never has — so every
  # studio created through sign-up got no subscription at all, and since every
  # limit check reads the plan, a brand-new account could not create a lead, a
  # package or a gallery. The failure was silent because the caller discarded
  # the result.
  defp trial_plan(nil) do
    case list_public_plans() do
      [] -> nil
      plans -> List.first(plans)
    end
  end

  defp trial_plan(key), do: current_plan(key)

  @doc """
  Move to a different plan.

  Refuses to downgrade into a plan the studio is already over — silently
  breaking a limit is worse than refusing the change, because the studio would
  discover it the next time they tried to work.
  """
  def change_plan(%Scope{} = scope, plan_key) do
    with :ok <- Authorization.authorize(scope, :"billing.write"),
         %Plan{} = plan <- current_plan(plan_key),
         subscription when not is_nil(subscription) <- get_subscription(scope),
         :ok <- ensure_fits(scope, plan) do
      subscription |> Subscription.changeset(%{plan_id: plan.id}) |> Repo.update()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def cancel(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"billing.write"),
         subscription when not is_nil(subscription) <- get_subscription(scope) do
      subscription |> Subscription.cancel_changeset() |> Repo.update()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def resume(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"billing.write"),
         subscription when not is_nil(subscription) <- get_subscription(scope) do
      subscription |> Subscription.resume_changeset() |> Repo.update()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  ## Add-ons

  def add_storage_block(%Scope{} = scope, quantity \\ 1) do
    with :ok <- Authorization.authorize(scope, :"billing.write"),
         subscription when not is_nil(subscription) <- get_subscription(scope) do
      %SubscriptionAddOn{}
      |> SubscriptionAddOn.changeset(%{
        subscription_id: subscription.id,
        studio_id: Scope.studio_id(scope),
        kind: "storage_block",
        quantity: quantity,
        unit_price_cents: 500,
        currency: subscription.plan.currency
      })
      |> Repo.insert()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def extend_gallery(%Scope{} = scope, gallery_id, days) do
    with :ok <- Authorization.authorize(scope, :"billing.write"),
         subscription when not is_nil(subscription) <- get_subscription(scope) do
      price = %{30 => 500, 60 => 900, 90 => 1200}[days] || 500

      Multi.new()
      |> Multi.insert(
        :add_on,
        SubscriptionAddOn.changeset(%SubscriptionAddOn{}, %{
          subscription_id: subscription.id,
          studio_id: Scope.studio_id(scope),
          kind: "gallery_extension",
          quantity: 1,
          unit_price_cents: price,
          currency: subscription.plan.currency,
          target_id: gallery_id
        })
      )
      |> Multi.run(:gallery, fn _repo, _ ->
        AperDesk.Galleries.extend_gallery(scope, gallery_id, days)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{gallery: gallery}} -> {:ok, gallery}
        {:error, _step, reason, _} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  ## Webhooks

  @doc """
  Apply a provider webhook exactly once.

  Recording the event id and applying the change share one transaction, so the
  two can never disagree. `fun` receives the repo and returns `{:ok, _}` or
  `{:error, _}`.
  """
  def handle_webhook(provider, event_id, event_type, payload \\ %{}, fun)
      when is_function(fun, 1) do
    Multi.new()
    |> Multi.insert(
      :event,
      ProcessedWebhookEvent.changeset(%ProcessedWebhookEvent{}, %{
        provider: provider,
        event_id: event_id,
        event_type: event_type,
        payload: payload
      })
    )
    |> Multi.run(:result, fn repo, _ -> fun.(repo) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{result: result}} ->
        {:ok, result}

      {:error, :event, changeset, _} ->
        if duplicate_event?(changeset), do: {:ok, :already_processed}, else: {:error, changeset}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Apply a subscription state change from the provider.

  Ignores an update whose period start is older than the one already stored:
  webhooks arrive out of order, and a late `updated` must not revert a change
  that superseded it.
  """
  def sync_subscription(repo, stripe_subscription_id, attrs) do
    case repo.get_by(Subscription, stripe_subscription_id: stripe_subscription_id) do
      nil ->
        {:error, :not_found}

      subscription ->
        if stale_update?(subscription, attrs) do
          {:ok, :ignored_stale}
        else
          repo.update(Subscription.sync_changeset(subscription, attrs))
        end
    end
  end

  ## Usage

  def usage(%Scope{} = scope) do
    subscription = get_subscription(scope)
    usage = Repo.get(AperDesk.Billing.StudioUsage, Scope.studio_id(scope))

    case subscription do
      nil ->
        {:error, :no_subscription}

      subscription ->
        # A brand-new studio has no counter row yet — the triggers create one on
        # its first lead or gallery. Falling back to a zeroed struct rather than
        # returning no meters means the plan panel shows "0 of 50" on day one
        # instead of rendering blank.
        usage = usage || %AperDesk.Billing.StudioUsage{studio_id: Scope.studio_id(scope)}

        # Only limits with a counter behind them. `gallery_window_days` is a plan
        # property, not something consumed — rendering it as "0 of 60" used
        # invites the reader to think they have 60 of something left.
        measurable = Map.keys(AperDesk.Billing.StudioUsage.limit_to_counter())

        meters =
          for key <- Plan.limit_keys(), key in measurable do
            %{
              key: key,
              used: AperDesk.Billing.StudioUsage.used(usage, key),
              limit: Plan.limit(subscription.plan, key),
              utilisation: AperDesk.Billing.StudioUsage.utilisation(usage, subscription.plan, key)
            }
          end

        {:ok, %{plan: subscription.plan, usage: usage, meters: meters}}
    end
  end

  def reconcile_usage(studio_id), do: Limits.reconcile(Repo, studio_id)

  ## Internals

  # Downgrading below current usage is refused rather than applied and broken.
  defp ensure_fits(%Scope{} = scope, %Plan{} = plan) do
    case Repo.get(AperDesk.Billing.StudioUsage, Scope.studio_id(scope)) do
      nil ->
        :ok

      usage ->
        Plan.limit_keys()
        |> Enum.find_value(:ok, fn key ->
          used = AperDesk.Billing.StudioUsage.used(usage, key)

          case Plan.limit(plan, key) do
            :unlimited -> nil
            limit when used <= limit -> nil
            limit -> {:error, {:over_limit_for_plan, key, used, limit}}
          end
        end)
    end
  end

  defp stale_update?(%Subscription{current_period_start: nil}, _attrs), do: false

  defp stale_update?(%Subscription{current_period_start: current}, attrs) do
    case attrs["current_period_start"] || attrs[:current_period_start] do
      nil -> false
      %DateTime{} = incoming -> DateTime.compare(incoming, current) == :lt
      _ -> false
    end
  end

  defp duplicate_event?(%Ecto.Changeset{errors: errors}),
    do: Enum.any?(errors, fn {field, _} -> field in [:provider, :event_id] end)

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)
end
