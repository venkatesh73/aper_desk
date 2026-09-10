defmodule AperDesk.Directory.StudioCategory do
  @moduledoc """
  Join row placing a studio in a directory category.

  `primary_category` decides which one a listing leads with in search results.
  It is a flag on the join rather than a column on the listing so that adding a
  category and promoting it are the same kind of write.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Directory.Category

  # Composite key: this table has no id of its own.
  @primary_key false
  @timestamps_opts []

  schema "studio_categories" do
    belongs_to :studio, Studio, primary_key: true
    belongs_to :category, Category, primary_key: true
    field :primary_category, :boolean, default: false
  end

  def changeset(studio_category, attrs) do
    studio_category
    |> cast(attrs, [:studio_id, :category_id, :primary_category])
    |> validate_required([:studio_id, :category_id])
    |> unique_constraint([:studio_id, :category_id],
      message: "this studio is already in that category"
    )
    |> foreign_key_constraint(:category_id)
  end
end
