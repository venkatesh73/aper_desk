defmodule AperDesk.Crm.Tagging do
  @moduledoc """
  Attaches a tag to any record, by type name and id.

  Polymorphic by string rather than by a column per taggable type, because the
  set of taggable things grows and a nullable FK per type would leave a table
  of mostly-empty columns with no constraint holding it together.

  The trade-off is a deliberate one: there is no foreign key on `taggable_id`,
  so deleting a tagged record leaves an orphan tagging. The nightly sweep
  clears those; the alternative — a join table per type — costs more than the
  orphans do.
  """
  use AperDesk.Schema

  alias AperDesk.Crm.Tag

  schema "taggings" do
    belongs_to :tag, Tag

    field :taggable_type, :string
    field :taggable_id, :binary_id

    timestamps(updated_at: false)
  end

  def changeset(tagging, attrs) do
    tagging
    |> cast(attrs, [:tag_id, :taggable_type, :taggable_id])
    |> validate_required([:tag_id, :taggable_type, :taggable_id])
    |> unique_constraint([:tag_id, :taggable_type, :taggable_id],
      message: "is already applied"
    )
    |> foreign_key_constraint(:tag_id)
  end

  @doc "The type name used for `subject`, e.g. `\"Lead\"`."
  def type_for(%module{}), do: module |> Module.split() |> List.last()
end
