defmodule AperDesk.Galleries.GalleryMedia do
  @moduledoc """
  One file in a gallery.

  `checksum` is the content hash. Two galleries delivered the same frame point
  at one stored object, so re-delivering a set to a second recipient costs no
  additional storage — which matters when the plan cap is the product's main
  pricing lever.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Galleries.Gallery

  @processing_states ~w(pending processing ready failed)

  schema "gallery_media" do
    belongs_to :gallery, Gallery
    belongs_to :studio, Studio

    field :filename, :string
    field :storage_key, :string
    field :thumb_key, :string
    field :preview_key, :string
    field :content_type, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer

    field :checksum, :string
    field :album, :string
    field :position, :integer, default: 0
    field :favourite_count, :integer, default: 0
    field :selected_count, :integer, default: 0
    field :processing_state, :string, default: "pending"

    timestamps()
  end

  def processing_states, do: @processing_states

  def changeset(media, attrs) do
    media
    |> cast(attrs, [
      :gallery_id,
      :studio_id,
      :filename,
      :storage_key,
      :thumb_key,
      :preview_key,
      :content_type,
      :byte_size,
      :width,
      :height,
      :checksum,
      :album,
      :position,
      :processing_state
    ])
    |> validate_required([
      :gallery_id,
      :studio_id,
      :filename,
      :storage_key,
      :content_type,
      :byte_size
    ])
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_inclusion(:processing_state, @processing_states)
    |> foreign_key_constraint(:gallery_id)
  end

  @doc "Record the output of the derivative-generation worker."
  def processed_changeset(media, attrs) do
    media
    |> cast(attrs, [:thumb_key, :preview_key, :width, :height])
    |> put_change(:processing_state, "ready")
  end

  def aspect_ratio(%__MODULE__{width: w, height: h})
      when is_integer(w) and is_integer(h) and h > 0,
      do: w / h

  def aspect_ratio(%__MODULE__{}), do: nil
end
