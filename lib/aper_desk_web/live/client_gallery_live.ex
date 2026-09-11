defmodule AperDeskWeb.ClientGalleryLive do
  @moduledoc """
  What the couple sees when they open the link.

  No sign-in, no account, no studio scope — the share token *is* the
  authorisation, and it is the only thing that opens anything. The gallery id
  is not a way in, so a token that has been revoked, expired or archived out
  gets the same page as one that never existed. Saying which would tell
  someone holding a stale link that there is something behind it.

  The token stays in the socket rather than being re-read from the URL on every
  event, and every write goes through the `%GalleryShare{}` it resolved to, so
  a favourite is always attributed to the link it came through — which is how
  a studio can tell the couple's picks apart from the best man's.
  """

  use AperDeskWeb, :live_view

  alias AperDesk.Galleries

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Galleries.open_shared_gallery(token) do
      {:ok, gallery, share} ->
        {:ok,
         socket
         |> assign(page_title: gallery.title)
         |> assign(gallery: gallery, share: share, filter: "all")
         |> assign(media: media(gallery))
         |> load_selections()
         |> assign(:page_layout, false)}

      {:error, _reason} ->
        {:ok, assign(socket, gallery: nil, share: nil, page_title: "Gallery")}
    end
  end

  @impl true
  def handle_event("favourite", %{"id" => id}, socket) do
    share = socket.assigns.share

    if MapSet.member?(socket.assigns.favourites, id) do
      Galleries.deselect_media(share, id, "favourite")
    else
      Galleries.select_media(share, id, "favourite")
    end

    {:noreply, load_selections(socket)}
  end

  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, assign(socket, filter: filter)}

  ## Data

  defp media(gallery) do
    import Ecto.Query

    AperDesk.Repo.all(
      from m in AperDesk.Galleries.GalleryMedia,
        where: m.gallery_id == ^gallery.id,
        order_by: [asc: m.position, asc: m.filename]
    )
  end

  defp load_selections(socket) do
    import Ecto.Query

    favourites =
      AperDesk.Repo.all(
        from s in AperDesk.Galleries.GallerySelection,
          where: s.share_id == ^socket.assigns.share.id and s.kind == "favourite",
          select: s.media_id
      )
      |> MapSet.new()

    assign(socket, favourites: favourites)
  end

  ## Presentation

  @doc "Only the frames the current filter asks for."
  def visible(media, "favourited", favourites),
    do: Enum.filter(media, &MapSet.member?(favourites, &1.id))

  def visible(media, _filter, _favourites), do: media

  def photo_url(media), do: AperDesk.Storage.url(media.preview_key || media.storage_key)

  def cover(gallery, media) do
    Enum.find(media, &(&1.id == gallery.cover_media_id)) || List.first(media)
  end
end
