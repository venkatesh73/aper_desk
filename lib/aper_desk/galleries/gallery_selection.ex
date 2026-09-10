defmodule AperDesk.Galleries.GallerySelection do
  @moduledoc """
  A client's pick: a favourite, an album choice, a print order or a reject.

  Attributed to the share that made it, so a couple can see which of them chose
  what. The `(media_id, share_id, kind)` unique index makes a double-tap on a
  heart icon idempotent rather than a duplicate row.
  """
  use AperDesk.Schema

  alias AperDesk.Galleries.{Gallery, GalleryMedia, GalleryShare}

  @kinds ~w(favourite album print reject)

  schema "gallery_selections" do
    belongs_to :gallery, Gallery
    belongs_to :media, GalleryMedia
    belongs_to :share, GalleryShare

    field :kind, :string, default: "favourite"
    field :note, :string

    timestamps(updated_at: false)
  end

  def kinds, do: @kinds

  def changeset(selection, attrs) do
    selection
    |> cast(attrs, [:gallery_id, :media_id, :share_id, :kind, :note])
    |> validate_required([:gallery_id, :media_id])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:media_id, :share_id, :kind],
      message: "has already been selected"
    )
    |> foreign_key_constraint(:media_id)
  end
end
