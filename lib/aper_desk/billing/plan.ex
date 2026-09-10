defmodule AperDesk.Billing.Plan do
  @moduledoc """
  A sellable plan, at a specific version.

  Limits are data on the row, not code. The system this replaces encoded them in
  a large module, which meant grandfathering a customer onto old limits, or
  running a pricing experiment, required a deploy. Here a price change means
  inserting a new *version* of the plan; existing subscriptions keep pointing at
  the version they were sold, so nobody is silently re-priced.

  A missing limit key means unlimited. That is deliberate: forgetting to add a
  key to the top plan should open a gate, never close one on a paying customer.
  """
  use AperDesk.Schema

  @limit_keys ~w(
    seats active_leads active_galleries storage_bytes gallery_window_days
    packages forms workflows contract_templates emails_per_lead
  )

  schema "plans" do
    field :key, :string
    field :version, :integer, default: 1
    field :name, :string
    field :tagline, :string
    field :monthly_price_cents, :integer
    field :yearly_price_cents, :integer
    field :currency, :string, default: "USD"
    field :extra_seat_price_cents, :integer

    field :limits, :map, default: %{}
    field :features, {:array, :string}, default: []

    field :position, :integer, default: 0
    field :public, :boolean, default: true
    field :stripe_monthly_price_id, :string
    field :stripe_yearly_price_id, :string

    timestamps()
  end

  def limit_keys, do: @limit_keys

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :key,
      :version,
      :name,
      :tagline,
      :monthly_price_cents,
      :yearly_price_cents,
      :currency,
      :extra_seat_price_cents,
      :limits,
      :features,
      :position,
      :public,
      :stripe_monthly_price_id,
      :stripe_yearly_price_id
    ])
    |> validate_required([:key, :name, :monthly_price_cents, :yearly_price_cents, :currency])
    |> validate_number(:monthly_price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:yearly_price_cents, greater_than_or_equal_to: 0)
    |> validate_inclusion(:currency, AperDesk.Money.supported_currencies())
    |> validate_limits()
    |> unique_constraint([:key, :version])
  end

  @doc """
  The limit for `key`, or `:unlimited`.

  Callers must handle `:unlimited` explicitly rather than receiving a very large
  number, so an accidental comparison against a sentinel can't quietly cap a
  studio at some arbitrary value.
  """
  def limit(%__MODULE__{limits: limits}, key) when is_binary(key) do
    case Map.get(limits || %{}, key) do
      nil -> :unlimited
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
    end
  end

  def limit(%__MODULE__{} = plan, key) when is_atom(key), do: limit(plan, Atom.to_string(key))

  @doc "Whether `used` is within the plan's limit for `key`."
  def within_limit?(%__MODULE__{} = plan, key, used) do
    case limit(plan, key) do
      :unlimited -> true
      max -> used <= max
    end
  end

  @doc "Whether one more of `key` would still fit."
  def has_headroom?(%__MODULE__{} = plan, key, used), do: within_limit?(plan, key, used + 1)

  def feature?(%__MODULE__{features: features}, feature), do: feature in (features || [])

  def price(%__MODULE__{} = plan, :monthly),
    do: AperDesk.Money.new(plan.monthly_price_cents, plan.currency)

  def price(%__MODULE__{} = plan, :yearly),
    do: AperDesk.Money.new(plan.yearly_price_cents, plan.currency)

  @doc "What a yearly commitment saves, in basis points of the monthly run rate."
  def yearly_saving_bps(%__MODULE__{monthly_price_cents: 0}), do: 0

  def yearly_saving_bps(%__MODULE__{} = plan) do
    annualised = plan.monthly_price_cents * 12
    saved = annualised - plan.yearly_price_cents
    if annualised > 0, do: div(saved * 10_000, annualised), else: 0
  end

  # An unknown limit key is almost always a typo, and a typo here means a limit
  # that is never enforced — a silent revenue leak rather than a loud error.
  defp validate_limits(changeset) do
    case get_field(changeset, :limits) do
      limits when is_map(limits) ->
        case Enum.reject(Map.keys(limits), &(&1 in @limit_keys)) do
          [] -> changeset
          unknown -> add_error(changeset, :limits, "unknown keys: #{Enum.join(unknown, ", ")}")
        end

      _ ->
        add_error(changeset, :limits, "must be a map")
    end
  end
end
