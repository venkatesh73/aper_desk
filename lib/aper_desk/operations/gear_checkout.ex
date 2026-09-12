defmodule AperDesk.Operations.GearCheckout do
  @moduledoc """
  Who has a piece of kit, and when it is due back.

  A partial unique index on `(gear_item_id) WHERE returned_at IS NULL` is what
  makes "one item, one pair of hands" true. A status column on the item would
  need the application to keep it in step, and two people checking out the same
  body at the same moment is exactly the race an index rules out and a column
  does not.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}
  alias AperDesk.Operations.GearItem
  alias AperDesk.Scheduling.Job

  schema "gear_checkouts" do
    belongs_to :studio, Studio
    belongs_to :gear_item, GearItem
    belongs_to :user, User
    belongs_to :job, Job

    field :taken_at, :utc_datetime_usec
    field :due_back_on, :date
    field :returned_at, :utc_datetime_usec
    field :condition_note, :string

    timestamps()
  end

  def changeset(checkout, attrs) do
    checkout
    |> cast(attrs, [
      :studio_id,
      :gear_item_id,
      :user_id,
      :job_id,
      :taken_at,
      :due_back_on,
      :condition_note
    ])
    |> validate_required([:studio_id, :gear_item_id, :taken_at])
    |> unique_constraint(:gear_item_id,
      name: :gear_checkouts_one_open_per_item,
      message: "is already checked out to somebody"
    )
  end

  def return_changeset(checkout, note \\ nil),
    do: change(checkout, returned_at: DateTime.utc_now(), condition_note: note)

  def out?(%__MODULE__{returned_at: nil}), do: true
  def out?(%__MODULE__{}), do: false

  @doc "Overdue means still out and past the day it was promised back."
  def overdue?(%__MODULE__{returned_at: nil, due_back_on: %Date{} = due}, today),
    do: Date.compare(today, due) == :gt

  def overdue?(%__MODULE__{}, _today), do: false
end
