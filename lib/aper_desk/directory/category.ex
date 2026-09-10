defmodule AperDesk.Directory.Category do
  @moduledoc "A shoot category a studio can be listed under in the public directory."
  use AperDesk.Schema

  @timestamps_opts []

  schema "categories" do
    field :key, :string
    field :name, :string
    field :position, :integer, default: 0
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:key, :name, :position])
    |> validate_required([:key, :name])
    |> validate_format(:key, ~r/^[a-z0-9_]+$/,
      message: "may only contain lowercase letters, numbers and underscores"
    )
    |> unique_constraint(:key)
  end
end
