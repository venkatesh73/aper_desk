defmodule AperDesk.Directory.PortfolioItem do
  @moduledoc """
  One public sample image.

  Kept apart from `GalleryMedia` on purpose: a portfolio piece is chosen for the
  world, a gallery frame is a client's private delivery. Sharing one table would
  make an accidental publish a single wrong boolean away.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio

  schema "portfolio_items" do
    belongs_to :studio, Studio

    field :title, :string
    field :caption, :string
    field :storage_key, :string
    field :url, :string
    field :shoot_type, :string
    field :width, :integer
    field :height, :integer
    field :position, :integer, default: 0
    field :published, :boolean, default: true

    timestamps()
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :studio_id,
      :title,
      :caption,
      :storage_key,
      :url,
      :shoot_type,
      :width,
      :height,
      :position,
      :published
    ])
    |> validate_required([:studio_id, :storage_key])
    |> foreign_key_constraint(:studio_id)
  end

  def aspect_ratio(%__MODULE__{width: w, height: h})
      when is_integer(w) and is_integer(h) and h > 0,
      do: w / h

  def aspect_ratio(%__MODULE__{}), do: nil
end
