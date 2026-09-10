defmodule AperDeskWeb.Graphql.Types.Gallery do
  @moduledoc "Client galleries, in list and detail form."

  use Absinthe.Schema.Notation

  object :gallery_summary do
    field(:id, non_null(:id))
    field(:title, non_null(:string))
    field(:status, non_null(:string))
    field(:status_label, :string)
    field(:status_tone, :tone)
    field(:cover_image_url, :string)
    field(:line1, :string)
    field(:line2, :string)
    field(:actions, list_of(:string))
  end

  object :gallery do
    field(:id, non_null(:id))
    field(:title, non_null(:string))
    field(:subtitle, :string)
    field(:photo_count, :integer)
    field(:size_gb, :float)
    field(:status, non_null(:string))
    field(:share_url, :string)

    @desc """
    Whether a password is set — never the password itself. The stored value is
    an Argon2 hash and cannot be reversed, which is the point.
    """
    field(:share_password, :string)

    field(:live_until, :string)
    field(:albums, list_of(:gallery_album))
    field(:client_picks, list_of(:client_pick))
    field(:photos, list_of(:photo))
    field(:settings, list_of(:gallery_setting))
    field(:activity, list_of(:activity_entry))
    field(:stats, :gallery_stats)
  end

  @desc "A grouping of the client's selections, with how many are in it."
  object :client_pick do
    field(:label, non_null(:string))
    field(:count, non_null(:integer))
  end

  object :gallery_album do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:count, non_null(:integer))
  end

  object :photo do
    field(:id, non_null(:id))
    field(:url, :string)
    field(:favourite_count, :integer)
    field(:picked, :boolean)
    field(:is_cover, :boolean)
  end

  object :gallery_setting do
    field(:key, non_null(:string))
    field(:value, :string)
    field(:options, list_of(:string))
  end

  object :gallery_stats do
    field(:views, :integer)
    field(:unique_visitors, :integer)
    field(:downloads, :integer)
  end
end
