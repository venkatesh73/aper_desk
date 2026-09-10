defmodule AperDesk.Billing.SubscriptionAddOn do
  @moduledoc """
  Something bought on top of the plan: a storage block, a gallery extension, an
  extra seat.

  One table for all three because they share a lifecycle (bought, active for a
  window, cancelled) and differ only in what they point at. `target_id` carries
  that difference: a gallery extension names the gallery it extends, a storage
  block applies to the whole studio and leaves it null.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Billing.Subscription

  @kinds ~w(storage_block gallery_extension extra_seat)

  # 50 GB per block, matching the published add-on. Defined once here so the
  # pricing page, the limit check and the Stripe line item cannot drift apart.
  @storage_block_bytes 50 * 1024 * 1024 * 1024

  schema "subscription_add_ons" do
    belongs_to :subscription, Subscription
    belongs_to :studio, Studio

    field :kind, :string
    field :quantity, :integer, default: 1
    field :unit_price_cents, :integer
    field :currency, :string, default: "USD"

    field :target_id, :binary_id
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    field :stripe_item_id, :string

    timestamps()
  end

  def kinds, do: @kinds
  def storage_block_bytes, do: @storage_block_bytes

  def changeset(add_on, attrs) do
    add_on
    |> cast(attrs, [
      :subscription_id,
      :studio_id,
      :kind,
      :quantity,
      :unit_price_cents,
      :currency,
      :target_id,
      :starts_at,
      :ends_at,
      :stripe_item_id
    ])
    |> validate_required([:subscription_id, :studio_id, :kind, :unit_price_cents, :currency])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
    |> put_starts_at()
    |> validate_target()
    |> foreign_key_constraint(:subscription_id)
  end

  def cancel_changeset(add_on, at \\ DateTime.utc_now()),
    do: change(add_on, cancelled_at: at)

  @doc "Whether this add-on is currently in force."
  def active?(%__MODULE__{cancelled_at: %DateTime{}}, _now), do: false

  def active?(%__MODULE__{starts_at: starts_at, ends_at: ends_at}, now) do
    started? = is_nil(starts_at) or DateTime.compare(now, starts_at) != :lt
    ended? = not is_nil(ends_at) and DateTime.compare(now, ends_at) == :gt
    started? and not ended?
  end

  @doc "What this add-on costs per period."
  def total(%__MODULE__{} = add_on),
    do:
      add_on.unit_price_cents
      |> AperDesk.Money.new(add_on.currency)
      |> AperDesk.Money.multiply(add_on.quantity)

  @doc "Bytes this add-on contributes, zero for non-storage kinds."
  def bytes(%__MODULE__{kind: "storage_block", quantity: quantity}),
    do: quantity * @storage_block_bytes

  def bytes(%__MODULE__{}), do: 0

  defp put_starts_at(changeset) do
    case get_field(changeset, :starts_at) do
      nil -> put_change(changeset, :starts_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  # A gallery extension that names no gallery extends nothing, and would be
  # billed for silently.
  defp validate_target(changeset) do
    if get_field(changeset, :kind) == "gallery_extension" and
         is_nil(get_field(changeset, :target_id)) do
      add_error(changeset, :target_id, "a gallery extension must name the gallery it extends")
    else
      changeset
    end
  end
end
