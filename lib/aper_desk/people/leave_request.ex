defmodule AperDesk.People.LeaveRequest do
  @moduledoc """
  Somebody asking not to be booked.

  Approval writes a `hold`-kind assignment covering the same days, and that
  assignment — not this row — is what the calendar and the clash check read.
  Leave that only existed here would be a note nobody's booking flow consults;
  leave that occupies a span in `assignments` makes booking a person who is
  away impossible rather than merely rude.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}
  alias AperDesk.Scheduling.Assignment

  @kinds ~w(holiday sick unpaid parental other)
  @statuses ~w(pending approved declined cancelled)
  @open_statuses ~w(pending approved)

  schema "leave_requests" do
    belongs_to :studio, Studio
    belongs_to :user, User
    belongs_to :decided_by, User
    belongs_to :assignment, Assignment

    field :kind, :string, default: "holiday"
    field :starts_on, :date
    field :ends_on, :date
    field :reason, :string
    field :status, :string, default: "pending"
    field :decided_at, :utc_datetime_usec
    field :decision_note, :string

    timestamps()
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
  def open_statuses, do: @open_statuses

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:studio_id, :user_id, :kind, :starts_on, :ends_on, :reason])
    |> validate_required([:studio_id, :user_id, :starts_on, :ends_on])
    |> validate_inclusion(:kind, @kinds)
    |> validate_dates()
  end

  def decision_changeset(request, status, decided_by_id, note \\ nil)
      when status in ~w(approved declined) do
    change(request,
      status: status,
      decided_by_id: decided_by_id,
      decided_at: DateTime.utc_now(),
      decision_note: note
    )
  end

  def cancel_changeset(request), do: change(request, status: "cancelled")

  def attach_assignment(request, assignment_id),
    do: change(request, assignment_id: assignment_id)

  @doc "How many days off this is, counting both ends."
  def days(%__MODULE__{starts_on: from, ends_on: to}) when not is_nil(from) and not is_nil(to),
    do: Date.diff(to, from) + 1

  def days(%__MODULE__{}), do: 0

  @doc """
  The span the calendar has to block out.

  Whole days in the studio's zone: leave is not booked by the hour, and a
  request that started at midnight UTC would free up the morning for a studio
  in Auckland.
  """
  def period(%__MODULE__{} = request, time_zone) do
    with {:ok, from} <- DateTime.new(request.starts_on, ~T[00:00:00], time_zone),
         {:ok, to} <- DateTime.new(Date.add(request.ends_on, 1), ~T[00:00:00], time_zone) do
      {:ok, {from, to}}
    else
      _ -> :error
    end
  end

  defp validate_dates(changeset) do
    with %Date{} = from <- get_field(changeset, :starts_on),
         %Date{} = to <- get_field(changeset, :ends_on),
         :lt <- Date.compare(to, from) do
      add_error(changeset, :ends_on, "cannot be before the first day")
    else
      _ -> changeset
    end
  end
end
