defmodule AperDesk.Operations.GearItem do
  @moduledoc """
  A piece of kit the studio owns.

  Retired rather than deleted: a checkout from last March names the body it was
  for, and removing the row would turn that history into a dangling id.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Operations.GearCheckout

  @categories ~w(body lens lighting audio support storage transport other)

  schema "gear_items" do
    belongs_to :studio, Studio

    field :name, :string
    field :category, :string, default: "other"
    field :serial, :string
    field :notes, :string
    field :retired_at, :utc_datetime_usec

    has_many :checkouts, GearCheckout, foreign_key: :gear_item_id

    timestamps()
  end

  def categories, do: @categories

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:studio_id, :name, :category, :serial, :notes])
    |> validate_required([:studio_id, :name])
    |> validate_inclusion(:category, @categories)
  end

  def retire_changeset(item), do: change(item, retired_at: DateTime.utc_now())
end
