defmodule AperDeskWeb.MediaController do
  @moduledoc """
  The only way to reach a gallery file.

  Objects used to be linked straight from the bucket, which meant an image URL
  outlived everything that was supposed to control it: revoking a share, the
  gallery's window closing, archiving it, and the code gate all stopped the
  *page* and none of them stopped the bytes. Anyone who kept a URL — or found
  one in a referrer header — kept the photograph.

  So every fetch comes through here, the share is re-resolved on each one, and
  what goes back is a redirect to a URL that expires in minutes. Revocation is
  checked at fetch time rather than at link time, which is the difference
  between a control and a suggestion.

  The cost is one redirect per image. That is a cheap app request against a
  presigned URL that is an HMAC, and it buys the only thing that makes the
  studio's controls mean anything.
  """
  use AperDeskWeb, :controller

  alias AperDesk.Galleries
  alias AperDesk.Galleries.GalleryMedia
  alias AperDesk.Scoped
  alias AperDesk.Storage

  # Long enough for a slow connection to finish the image, short enough that a
  # URL copied out of devtools is stale before it is useful.
  @ttl 300

  @doc "A file behind a client's share link."
  def client(conn, %{"token" => token, "id" => id} = params) do
    unlocked = AperDeskWeb.ClientGalleryController.unlocked(conn)
    variant = variant(params)

    case Galleries.fetch_shared_media(token, id, unlocked) do
      {:ok, media, gallery, share} ->
        if variant == :original and not downloadable?(gallery, share) do
          gone(conn)
        else
          send_object(conn, key(media, variant))
        end

      {:error, _reason} ->
        gone(conn)
    end
  end

  @doc "A file in the studio's own gallery, for the people who work there."
  def studio(conn, %{"id" => id} = params) do
    case Scoped.fetch(GalleryMedia, conn.assigns.current_scope, id) do
      {:ok, media} -> send_object(conn, key(media, variant(params)))
      {:error, _reason} -> gone(conn)
    end
  end

  @doc """
  The absolute studio-side URL for one file.

  Absolute because the mobile client is not on this origin and has no base to
  resolve a path against.
  """
  def studio_url(media_id, variant),
    do: AperDeskWeb.Endpoint.url() <> ~p"/app/media/#{media_id}/#{variant}"

  ## Internals

  defp variant(%{"variant" => "thumb"}), do: :thumb
  defp variant(%{"variant" => "original"}), do: :original
  defp variant(_params), do: :preview

  # The fallbacks are what made the derivative columns invisible for so long,
  # but they are still right: a frame whose job has not run yet must render.
  defp key(%GalleryMedia{} = media, :thumb), do: media.thumb_key || media.storage_key
  defp key(%GalleryMedia{} = media, :preview), do: media.preview_key || media.storage_key
  defp key(%GalleryMedia{} = media, :original), do: media.storage_key

  defp downloadable?(gallery, share), do: gallery.download_enabled and share.can_download

  defp send_object(conn, nil), do: gone(conn)

  defp send_object(conn, key) do
    case Storage.signed_url(key, @ttl) do
      {:ok, url} ->
        conn
        # Never a shared cache: the URL behind this is private to one viewer
        # for a few minutes, and a CDN holding the redirect would hand it to
        # the next person to ask.
        |> put_resp_header("cache-control", "private, max-age=60")
        |> redirect(external: url)

      {:error, _reason} ->
        gone(conn)
    end
  end

  # One answer for revoked, expired, archived, gated, wrong gallery and never
  # existed. Telling them apart tells someone holding a stale link that there
  # is something behind it.
  defp gone(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(404, "")
    |> halt()
  end
end
