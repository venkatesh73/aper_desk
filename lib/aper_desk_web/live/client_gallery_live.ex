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

  A gallery with `requires_otp` set puts a code in front of all of that. The
  code is mailed to the address the studio named on the share and nowhere else,
  and until it is redeemed this socket holds no media at all — a gate that
  loads the photographs and then declines to draw them is not a gate.
  """

  use AperDeskWeb, :live_view

  alias AperDesk.Galleries

  @impl true
  def mount(%{"token" => token}, session, socket) do
    unlocked = session["unlocked_galleries"] || []

    # Resolved before anything is opened, so a visit is not recorded for
    # someone who never got past the gate and — the part that matters — the
    # photographs are never loaded into a socket that has not proved itself.
    case Galleries.resolve_shared_gallery(token) do
      {:ok, gallery, share} ->
        cond do
          Galleries.gated?(gallery, unlocked) ->
            {:ok, gate(socket, token, gallery, share)}

          # Counted once, not twice. A LiveView mounts twice — the dead render
          # and then the socket — and recording both would tell the studio the
          # client came back when they only arrived.
          connected?(socket) ->
            {:ok, gallery, share} = Galleries.open_shared_gallery(token)
            {:ok, opened(socket, token, gallery, share)}

          true ->
            {:ok, opened(socket, token, gallery, share)}
        end

      {:error, _reason} ->
        {:ok,
         socket
         |> assign(gallery: nil, share: nil, stage: :closed, page_title: "Gallery")
         |> assign(token: token, email: "", error: nil, media: [], filter: "all")
         |> assign(favourites: MapSet.new())
         |> assign(:page_layout, false)}
    end
  end

  defp opened(socket, token, gallery, share) do
    socket
    |> assign(page_title: gallery.title)
    |> assign(gallery: gallery, share: share, token: token, filter: "all", stage: :open)
    |> assign(media: media(gallery))
    |> load_selections()
    |> assign(:page_layout, false)
  end

  defp gate(socket, token, gallery, share) do
    socket
    |> assign(page_title: gallery.title)
    |> assign(gallery: gallery, share: share, token: token)
    |> assign(stage: if(is_nil(share.email), do: :unaddressed, else: :email))
    |> assign(email: "", error: nil)
    # Nothing about the shoot beyond its title, and no media at all: this
    # socket belongs to someone who has not yet shown they should have it.
    |> assign(media: [], favourites: MapSet.new(), filter: "all")
    |> assign(:page_layout, false)
  end

  ## The gate

  @impl true
  def handle_event("request-code", %{"email" => email}, socket) do
    case Galleries.request_access_code(socket.assigns.token, email) do
      :ok ->
        {:noreply, assign(socket, stage: :code, email: email, error: nil)}

      {:error, :no_recipient} ->
        {:noreply, assign(socket, stage: :unaddressed)}

      {:error, _reason} ->
        # Includes a link that went stale between loading the page and
        # submitting it. Same page either way; it will not open.
        {:noreply, assign(socket, stage: :closed, gallery: nil)}
    end
  end

  def handle_event("submit-code", %{"code" => code}, socket) do
    token = socket.assigns.token

    case Galleries.redeem_access_code(token, socket.assigns.email, code) do
      {:ok, gallery} ->
        # Out to the controller and straight back, so the unlock lands in the
        # session and survives a refresh.
        pass = AperDeskWeb.ClientGalleryController.sign(gallery.id)
        {:noreply, redirect(socket, to: ~p"/g/#{token}/unlock?pass=#{pass}")}

      {:error, :expired_or_exhausted} ->
        {:noreply,
         assign(socket,
           stage: :email,
           error: "That code has expired or been tried too many times. Ask for a new one."
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "That code is not right.")}
    end
  end

  def handle_event("start-over", _params, socket),
    do: {:noreply, assign(socket, stage: :email, error: nil)}

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

  @doc """
  Where the browser fetches a frame from.

  Through the app rather than the bucket, so the share is re-checked on every
  image. A link the studio revoked stops serving photographs, not just pages.
  """
  def photo_url(token, media), do: ~p"/g/#{token}/media/#{media.id}/preview"

  def thumb_url(token, media), do: ~p"/g/#{token}/media/#{media.id}/thumb"

  def cover(gallery, media) do
    Enum.find(media, &(&1.id == gallery.cover_media_id)) || List.first(media)
  end
end
