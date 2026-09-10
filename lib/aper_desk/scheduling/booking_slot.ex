defmodule AperDesk.Scheduling.BookingSlot do
  @moduledoc """
  A concrete slot offered on the public booking page.

  Slots are materialised rows rather than computed on the fly from availability
  rules, because a client needs to be able to take one and have it actually be
  gone for everyone else. A computed slot has nothing to lock.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}
  alias AperDesk.Catalog.Package
  alias AperDesk.Crm.Lead

  @statuses ~w(open held booked cancelled)

  schema "booking_slots" do
    belongs_to :studio, Studio
    belongs_to :package, Package
    belongs_to :user, User
    belongs_to :lead, Lead

    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :status, :string, default: "open"
    field :booked_by_email, :string
    field :booked_at, :utc_datetime_usec

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(slot, attrs) do
    slot
    |> cast(attrs, [
      :studio_id,
      :package_id,
      :user_id,
      :lead_id,
      :starts_at,
      :ends_at,
      :status
    ])
    |> validate_required([:studio_id, :starts_at, :ends_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_order()
  end

  @doc """
  Claim the slot for a client.

  Guarded on the row still being open, so two clients submitting at the same
  moment cannot both succeed — the second update matches no row.
  """
  def book_changeset(slot, email, at \\ DateTime.utc_now()) do
    slot
    |> change(status: "booked", booked_by_email: email, booked_at: at)
    |> validate_required([:booked_by_email])
  end

  def cancel_changeset(slot), do: change(slot, status: "cancelled")

  def open?(%__MODULE__{status: "open"}), do: true
  def open?(%__MODULE__{}), do: false

  def duration_minutes(%__MODULE__{starts_at: from, ends_at: to}),
    do: DateTime.diff(to, from, :second) |> div(60)

  defp validate_order(changeset) do
    from = get_field(changeset, :starts_at)
    to = get_field(changeset, :ends_at)

    if is_struct(from, DateTime) and is_struct(to, DateTime) and
         DateTime.compare(to, from) != :gt do
      add_error(changeset, :ends_at, "must be after the start time")
    else
      changeset
    end
  end
end
