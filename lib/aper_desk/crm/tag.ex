defmodule AperDesk.Crm.Tag do
  @moduledoc "A studio-defined label. Names are case-insensitive and unique per studio."
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio

  @kinds ~w(general source segment priority venue)

  schema "tags" do
    belongs_to :studio, Studio

    field :name, :string
    field :color, :string
    field :kind, :string, default: "general"

    timestamps()
  end

  def kinds, do: @kinds

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:studio_id, :name, :color, :kind])
    |> validate_required([:studio_id, :name])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 40)
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:color, ~r/^#[0-9A-Fa-f]{6}$/, message: "must be a hex colour")
    |> unique_constraint([:studio_id, :name], message: "already exists")
  end
end
