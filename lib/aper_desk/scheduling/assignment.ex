defmodule AperDesk.Scheduling.Assignment do
  @moduledoc """
  A reservation of one person's time — a shoot, a travel day, leave, an editing
  block or a soft hold.

  Every one of these is a `tstzrange` guarded by a GiST exclusion constraint,
  so the database, not the application, is the authority on whether someone is
  double-booked.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}
  alias AperDesk.Scheduling.Job

  @kinds ~w(shoot travel hold leave edit other)
  @roles ~w(lead_photographer second_shooter assistant editor videographer coordinator)
  @payout_statuses ~w(none pending approved paid)

  schema "assignments" do
    belongs_to :studio, Studio
    belongs_to :user, User
    belongs_to :job, Job

    field :kind, :string, default: "shoot"
    field :role, :string, default: "lead_photographer"
    field :label, :string

    # Read back from Postgres as a raw tstzrange; the context converts.
    field :period, AperDesk.Scheduling.TstzRange

    field :expires_at, :utc_datetime_usec
    field :released_at, :utc_datetime_usec

    field :payout_cents, :integer
    field :payout_currency, :string
    field :payout_status, :string, default: "none"

    timestamps()
  end

  def kinds, do: @kinds
  def roles, do: @roles

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :studio_id,
      :user_id,
      :job_id,
      :kind,
      :role,
      :label,
      :period,
      :expires_at,
      :payout_cents,
      :payout_currency,
      :payout_status
    ])
    |> validate_required([:studio_id, :user_id, :period])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:payout_status, @payout_statuses)
    |> validate_hold_expiry()
    # Surfaced as a clash rather than a 500. `AperDesk.Scheduling` catches this
    # and turns it into the "resolve this clash" flow the UI shows.
    |> exclusion_constraint(:period,
      name: :assignments_no_overlap,
      message: "clashes with another commitment for this person"
    )
  end

  def release_changeset(assignment),
    do: change(assignment, released_at: DateTime.utc_now())

  # A hold that never expires is just a booking nobody agreed to.
  defp validate_hold_expiry(changeset) do
    if get_field(changeset, :kind) == "hold" and is_nil(get_field(changeset, :expires_at)) do
      add_error(changeset, :expires_at, "is required for a hold")
    else
      changeset
    end
  end
end
