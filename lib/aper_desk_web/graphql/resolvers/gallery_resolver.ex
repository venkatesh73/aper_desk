defmodule AperDeskWeb.Graphql.Resolvers.GalleryResolver do
  @moduledoc "Galleries in list and detail form, including the client's picks."

  alias AperDesk.Galleries
  alias AperDesk.Galleries.Gallery
  alias AperDeskWeb.Graphql.Resolvers.Helpers

  def list(_parent, args, %{context: %{scope: scope}}) do
    opts = if args[:status], do: [status: args[:status]], else: []

    with {:ok, galleries} <- Galleries.list_galleries(scope, opts) do
      {:ok, Enum.map(galleries, &summary/1)}
    end
  end

  def get(_parent, %{id: id}, %{context: %{scope: scope}}) do
    with {:ok, gallery} <- Galleries.fetch_gallery(scope, id) do
      media = Helpers.ok_or(Galleries.list_media(scope, gallery.id), [])
      favourites = Helpers.ok_or(Galleries.list_selections(scope, gallery.id, "favourite"), [])

      favourite_counts = Enum.frequencies_by(favourites, & &1.media_id)

      {:ok,
       %{
         id: gallery.id,
         title: gallery.title,
         subtitle: gallery.description,
         photo_count: gallery.media_count,
         size_gb: Helpers.to_gb(gallery.bytes_total),
         status: gallery.status,
         share_url: nil,
         # Never the password itself — only whether one is set. The stored
         # value is an Argon2 hash and is not reversible.
         share_password: if(gallery.password_hash, do: "set", else: nil),
         live_until: gallery.expires_at && Helpers.date_label(gallery.expires_at),
         albums: albums(media),
         client_picks: [
           %{label: "Favourites", count: length(favourites)},
           %{label: "Albums", count: length(albums(media))}
         ],
         photos:
           Enum.map(media, fn item ->
             %{
               id: item.id,
               # A storage key is not a URL, and this used to hand one to the
               # mobile client as though it were. Now it is the same authorised
               # route the web app fetches through.
               url: AperDeskWeb.MediaController.studio_url(item.id, "preview"),
               favourite_count: Map.get(favourite_counts, item.id, 0),
               picked: Map.has_key?(favourite_counts, item.id),
               is_cover: gallery.cover_media_id == item.id
             }
           end),
         settings: settings(gallery),
         activity: [],
         stats: %{
           views: view_count(scope, gallery),
           unique_visitors: nil,
           downloads: gallery.download_count
         }
       }}
    end
  end

  defp summary(%Gallery{} = gallery) do
    %{
      id: gallery.id,
      title: gallery.title,
      status: gallery.status,
      status_label: Helpers.humanise(gallery.status),
      status_tone: status_tone(gallery),
      cover_image_url: nil,
      line1: "#{gallery.media_count} photos · #{Helpers.to_gb(gallery.bytes_total)} GB",
      line2: line2(gallery),
      actions: actions(gallery)
    }
  end

  # A gallery about to expire is the one thing on this screen that is
  # time-critical, so it gets the warning colour rather than the status colour.
  defp status_tone(%Gallery{} = gallery) do
    days = Gallery.days_remaining(gallery, DateTime.utc_now())

    cond do
      gallery.status == "archived" -> :neutral
      is_integer(days) and days <= 7 -> :critical
      is_integer(days) and days <= 30 -> :warning
      gallery.status == "delivered" -> :positive
      true -> :neutral
    end
  end

  defp line2(%Gallery{status: "delivered"} = gallery) do
    case Gallery.days_remaining(gallery, DateTime.utc_now()) do
      nil -> "Delivered"
      days -> "Live for #{days} more days"
    end
  end

  defp line2(%Gallery{status: "archived", purge_after: nil}), do: "Archived"

  defp line2(%Gallery{status: "archived"} = gallery),
    do: "Recoverable until #{Helpers.date_label(gallery.purge_after)}"

  defp line2(%Gallery{}), do: "Not delivered yet"

  defp actions(%Gallery{status: "draft"}), do: ["upload", "deliver"]
  defp actions(%Gallery{status: "ready"}), do: ["deliver", "share"]
  defp actions(%Gallery{status: "delivered"}), do: ["share", "extend", "download"]
  defp actions(%Gallery{status: "archived"}), do: ["restore"]
  defp actions(%Gallery{}), do: []

  defp albums(media) do
    media
    |> Enum.reject(&is_nil(&1.album))
    |> Enum.group_by(& &1.album)
    |> Enum.map(fn {name, items} -> %{id: name, name: name, count: length(items)} end)
  end

  defp settings(%Gallery{} = gallery) do
    [
      %{key: "downloads", value: to_string(gallery.download_enabled), options: ["true", "false"]},
      %{
        key: "download_limit",
        value: to_string(gallery.download_limit || "unlimited"),
        options: []
      },
      %{
        key: "watermark",
        value: to_string(gallery.watermark_enabled),
        options: ["true", "false"]
      },
      %{
        key: "studio_badge",
        value: to_string(gallery.show_studio_badge),
        options: ["true", "false"]
      },
      %{key: "requires_otp", value: to_string(gallery.requires_otp), options: ["true", "false"]}
    ]
  end

  defp view_count(scope, gallery) do
    import Ecto.Query

    AperDesk.Repo.one(
      from s in AperDesk.Galleries.GalleryShare,
        where: s.gallery_id == ^gallery.id,
        select: coalesce(sum(s.view_count), 0)
    )
    |> case do
      %Decimal{} = d -> Decimal.to_integer(d)
      n when is_integer(n) -> n
      _ -> 0
    end
    |> tap(fn _ -> scope end)
  end
end
