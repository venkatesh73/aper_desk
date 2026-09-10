defmodule AperDesk.Billing.Subscription do
  @moduledoc """
  What a studio is on, and until when.

  `plan_id` points at a plan *version*, which is what makes grandfathering
  automatic: raising prices means inserting a new version, and every existing
  subscription keeps resolving to the terms it was sold.

  `data_retained_until` makes the "30 days after you cancel" promise auditable.
  It is a stored date rather than a rule applied at read time, so the purge job
  and the UI cannot disagree about when access ends.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Billing.{Plan, SubscriptionAddOn}

  @statuses ~w(trialing active past_due paused cancelled expired)
  # Statuses in which the studio may keep using the product.
  @entitled_statuses ~w(trialing active past_due)
  @billing_periods ~w(monthly yearly)

  @trial_days 30
  @retention_days 30

  schema "subscriptions" do
    belongs_to :studio, Studio
    belongs_to :plan, Plan

    field :status, :string, default: "trialing"
    field :billing_period, :string, default: "monthly"
    field :seats, :integer, default: 1

    field :trial_ends_at, :utc_datetime_usec
    field :current_period_start, :utc_datetime_usec
    field :current_period_end, :utc_datetime_usec
    field :cancel_at_period_end, :boolean, default: false
    field :cancelled_at, :utc_datetime_usec
    field :data_retained_until, :utc_datetime_usec

    field :stripe_customer_id, :string
    field :stripe_subscription_id, :string

    has_many :add_ons, SubscriptionAddOn, foreign_key: :subscription_id

    timestamps()
  end

  def statuses, do: @statuses
  def entitled_statuses, do: @entitled_statuses
  def billing_periods, do: @billing_periods
  def trial_days, do: @trial_days

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :studio_id,
      :plan_id,
      :status,
      :billing_period,
      :seats,
      :trial_ends_at,
      :current_period_start,
      :current_period_end,
      :cancel_at_period_end,
      :stripe_customer_id,
      :stripe_subscription_id
    ])
    |> validate_required([:studio_id, :plan_id, :status, :billing_period])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:billing_period, @billing_periods)
    |> validate_number(:seats, greater_than: 0)
    |> unique_constraint(:studio_id, message: "this studio already has a subscription")
    |> unique_constraint(:stripe_subscription_id)
    |> foreign_key_constraint(:plan_id)
  end

  @doc "Start a studio on its free trial. No card, per the pricing page."
  def trial_changeset(subscription, plan_id, at \\ DateTime.utc_now()) do
    change(subscription,
      plan_id: plan_id,
      status: "trialing",
      trial_ends_at: DateTime.add(at, @trial_days * 24 * 60 * 60, :second),
      current_period_start: at
    )
  end

  @doc """
  Cancel. Access continues to the end of the paid period, and data stays
  reachable for #{@retention_days} days after that.
  """
  def cancel_changeset(subscription, at \\ DateTime.utc_now()) do
    ends_at = subscription.current_period_end || at

    change(subscription,
      cancel_at_period_end: true,
      cancelled_at: at,
      data_retained_until: DateTime.add(ends_at, @retention_days * 24 * 60 * 60, :second)
    )
  end

  @doc "Undo a pending cancellation, before the period actually ends."
  def resume_changeset(subscription),
    do:
      change(subscription,
        cancel_at_period_end: false,
        cancelled_at: nil,
        data_retained_until: nil
      )

  @doc "Apply a state change that arrived from Stripe."
  def sync_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :status,
      :current_period_start,
      :current_period_end,
      :cancel_at_period_end,
      :seats
    ])
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Whether the studio may currently use the product."
  def entitled?(%__MODULE__{status: status}, _now) when status not in @entitled_statuses,
    do: false

  def entitled?(%__MODULE__{status: "trialing", trial_ends_at: nil}, _now), do: true

  def entitled?(%__MODULE__{status: "trialing", trial_ends_at: ends_at}, now),
    do: DateTime.compare(now, ends_at) != :gt

  def entitled?(%__MODULE__{}, _now), do: true

  @doc "Whether cancelled data is still within its recovery window."
  def data_recoverable?(%__MODULE__{data_retained_until: nil}, _now), do: true

  def data_recoverable?(%__MODULE__{data_retained_until: until}, now),
    do: DateTime.compare(now, until) != :gt

  @doc "Days left of trial, or nil when not trialing."
  def trial_days_remaining(
        %__MODULE__{status: "trialing", trial_ends_at: %DateTime{} = ends_at},
        now
      ),
      do: ends_at |> DateTime.diff(now, :second) |> max(0) |> div(86_400)

  def trial_days_remaining(%__MODULE__{}, _now), do: nil

  @doc """
  Total storage available: the plan's allowance plus every active storage block.

  Add-ons are summed here rather than folded into the plan so that a studio can
  see, on one screen, which part of its cap it is paying extra for.
  """
  def storage_limit_bytes(%__MODULE__{plan: %Plan{} = plan} = subscription, now) do
    case Plan.limit(plan, "storage_bytes") do
      :unlimited ->
        :unlimited

      base ->
        extra =
          subscription.add_ons
          |> List.wrap()
          |> Enum.filter(&(&1.kind == "storage_block" and SubscriptionAddOn.active?(&1, now)))
          |> Enum.reduce(0, fn add_on, sum ->
            sum + add_on.quantity * SubscriptionAddOn.storage_block_bytes()
          end)

        base + extra
    end
  end
end
