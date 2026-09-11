defmodule AperDeskWeb.GalleryLive do
  @moduledoc """
  One gallery: its frames, its albums, what the client has picked, and the
  link they see it through.

  Uploads are consumed straight into `AperDesk.Storage` and then handed to
  `Galleries.add_media/3`, which takes the plan's storage lock in the same
  transaction as the insert. The order matters: the file is written first so
  that a refused upload leaves an orphaned object rather than a row pointing
  at nothing. An orphan costs disk until a sweep finds it; a row with no file
  behind it is a broken image in a client's wedding gallery.

  The share token is shown exactly once, when it is created. Only its hash is
  stored, so there is no second chance to read it — which is the point.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Formats
  alias AperDesk.Galleries
  alias AperDesk.Storage

  @max_entries 50
  @max_bytes 100_000_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Galleries.fetch_gallery(scope, id) do
      {:ok, gallery} ->
        {:ok,
         socket
         |> assign(page_title: gallery.title)
         |> assign(gallery: gallery, album: nil, filter: "all", share_token: nil)
         |> allow_upload(:photos,
           accept: Enum.map(Storage.extensions(), &".#{&1}"),
           max_entries: @max_entries,
           max_file_size: @max_bytes
         )
         |> load()}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That gallery is not here.")
         |> push_navigate(to: ~p"/app/galleries")}
    end
  end

  @impl true
  def handle_event("validate-upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :photos, ref)}

  def handle_event("upload", _params, socket) do
    scope = socket.assigns.current_scope
    gallery = socket.assigns.gallery

    results =
      consume_uploaded_entries(socket, :photos, fn %{path: path}, entry ->
        {:ok, store(scope, gallery, path, entry)}
      end)

    {added, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

    socket =
      socket
      |> maybe_set_cover(added)
      |> load()
      |> flash_for(added, failed)

    {:noreply, socket}
  end

  def handle_event("album", %{"album" => album}, socket) do
    album = if album == "", do: nil, else: album
    {:noreply, socket |> assign(album: album) |> load()}
  end

  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, socket |> assign(filter: filter) |> load()}

  def handle_event("remove", %{"id" => id}, socket) do
    case Galleries.remove_media(socket.assigns.current_scope, id) do
      {:ok, media} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{media.filename} removed.")
         |> reload_gallery()
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove it: #{inspect(reason)}")}
    end
  end

  def handle_event("cover", %{"id" => id}, socket) do
    case Galleries.update_gallery(socket.assigns.current_scope, socket.assigns.gallery.id, %{
           "cover_media_id" => id
         }) do
      {:ok, gallery} ->
        {:noreply, socket |> assign(gallery: gallery) |> put_flash(:info, "Cover set.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not set the cover.")}
    end
  end

  def handle_event("deliver", _params, socket) do
    case Galleries.deliver_gallery(socket.assigns.current_scope, socket.assigns.gallery.id) do
      {:ok, gallery} ->
        {:noreply,
         socket
         |> assign(gallery: gallery)
         |> put_flash(
           :info,
           "Delivered. The window is open until #{window_end(socket, gallery)}."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not deliver it: #{inspect(reason)}")}
    end
  end

  def handle_event("extend", %{"days" => days}, socket) do
    days = String.to_integer(days)

    case Galleries.extend_gallery(socket.assigns.current_scope, socket.assigns.gallery.id, days) do
      {:ok, gallery} ->
        {:noreply,
         socket
         |> assign(gallery: gallery)
         |> put_flash(:info, "Extended by #{days} days.")}

      {:error, :no_window} ->
        {:noreply,
         put_flash(socket, :error, "There is no window to extend — deliver the gallery first.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not extend it: #{inspect(reason)}")}
    end
  end

  def handle_event("share", _params, socket) do
    scope = socket.assigns.current_scope

    # A share is required to carry a label, so that a studio looking at four
    # live links can tell which is the couple's and which went to the venue.
    # Until this screen lets them be named, the gallery's own title is the one
    # honest answer.
    attrs = %{"label" => socket.assigns.gallery.title}

    case Galleries.share_gallery(scope, socket.assigns.gallery.id, attrs) do
      {:ok, _share, token} ->
        {:noreply,
         socket
         |> assign(share_token: token)
         |> load()
         |> put_flash(:info, "Link created. Copy it now — it is not shown again.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create a link: #{inspect(reason)}")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case Galleries.revoke_share(socket.assigns.current_scope, id) do
      {:ok, _share} ->
        {:noreply,
         socket |> assign(share_token: nil) |> load() |> put_flash(:info, "Link revoked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not revoke it: #{inspect(reason)}")}
    end
  end

  def handle_event("settings", %{"gallery" => params}, socket) do
    case Galleries.update_gallery(socket.assigns.current_scope, socket.assigns.gallery.id, params) do
      {:ok, gallery} ->
        {:noreply, socket |> assign(gallery: gallery) |> put_flash(:info, "Saved.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Those settings would not save.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  ## Uploading

  defp store(scope, gallery, path, entry) do
    key = Storage.key_for(gallery.studio_id, gallery.id, entry.client_name)

    with {:ok, key} <- Storage.put(key, path, content_type: entry.client_type),
         {:ok, media} <-
           Galleries.add_media(scope, gallery.id, %{
             "filename" => entry.client_name,
             "storage_key" => key,
             "content_type" => entry.client_type || "application/octet-stream",
             "byte_size" => byte_size_of(path, entry)
           }) do
      {:ok, media}
    else
      {:error, reason} ->
        # The object was written but the row was refused — the plan is full, or
        # the insert failed. Take the file back out rather than paying for it.
        Storage.delete(key)
        {:error, reason}
    end
  end

  # `entry.client_size` is what the browser claimed. The file on disk is what
  # the studio is actually charged for, so that is what the cap is checked
  # against; the claim is only a fallback if the file has already gone.
  defp byte_size_of(path, entry) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > 0 -> size
      _ -> entry.client_size || 0
    end
  end

  defp maybe_set_cover(socket, []), do: socket

  defp maybe_set_cover(%{assigns: %{gallery: %{cover_media_id: nil}}} = socket, [{:ok, media} | _]) do
    case Galleries.update_gallery(socket.assigns.current_scope, socket.assigns.gallery.id, %{
           "cover_media_id" => media.id
         }) do
      {:ok, gallery} -> assign(socket, gallery: gallery)
      _ -> socket
    end
  end

  defp maybe_set_cover(socket, _added), do: socket

  defp flash_for(socket, added, []) when added != [],
    do: put_flash(socket, :info, "#{length(added)} added.")

  defp flash_for(socket, [], failed) when failed != [],
    do: put_flash(socket, :error, refusal(failed))

  defp flash_for(socket, added, failed) when added != [] and failed != [],
    do: put_flash(socket, :error, "#{length(added)} added. #{refusal(failed)}")

  defp flash_for(socket, _added, _failed), do: socket

  defp refusal(failed) do
    case Enum.find_value(failed, fn {:error, reason} -> reason end) do
      {:limit_reached, "storage_bytes", limit} ->
        "#{length(failed)} refused: that would take you past your #{AperDeskWeb.GalleriesLive.size(limit)} of storage."

      {:limit_reached, _key, _limit} ->
        "#{length(failed)} refused: your plan is full."

      _other ->
        "#{length(failed)} could not be stored."
    end
  end

  ## Data

  defp reload_gallery(socket) do
    case Galleries.fetch_gallery(socket.assigns.current_scope, socket.assigns.gallery.id) do
      {:ok, gallery} -> assign(socket, gallery: gallery)
      _ -> socket
    end
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    gallery = socket.assigns.gallery

    media = Galleries.list_media(scope, gallery.id)

    favourites =
      case Galleries.list_selections(scope, gallery.id, "favourite") do
        {:ok, selections} -> selections
        _ -> []
      end

    picks =
      case Galleries.list_selections(scope, gallery.id, "album") do
        {:ok, selections} -> selections
        _ -> []
      end

    socket
    |> assign(media: media)
    |> assign(visible: filtered(media, socket.assigns.album, socket.assigns.filter, favourites))
    |> assign(albums: albums(media))
    |> assign(favourites: favourites, picks: picks)
    |> assign(shares: shares(scope, gallery))
  end

  defp shares(scope, gallery) do
    case Galleries.list_shares(scope, gallery.id) do
      {:ok, shares} -> shares
      _ -> []
    end
  end

  defp albums(media) do
    media
    |> Enum.group_by(& &1.album)
    |> Enum.reject(fn {album, _} -> is_nil(album) end)
    |> Enum.map(fn {album, list} -> {album, length(list)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp filtered(media, album, filter, favourites) do
    favourited = favourites |> Enum.map(& &1.media_id) |> MapSet.new()

    media
    |> then(fn list -> if album, do: Enum.filter(list, &(&1.album == album)), else: list end)
    |> then(fn list ->
      case filter do
        "favourited" -> Enum.filter(list, &MapSet.member?(favourited, &1.id))
        _ -> list
      end
    end)
  end

  defp window_end(socket, gallery),
    do: Formats.date(socket.assigns.current_scope, gallery.expires_at) || "the plan's window"

  ## Presentation

  defdelegate size(bytes), to: AperDeskWeb.GalleriesLive
  defdelegate status_label(status), to: AperDeskWeb.GalleriesLive
  defdelegate status_tone(status), to: AperDeskWeb.GalleriesLive

  @doc "The line under the title: where it is up to, in one sentence."
  def subtitle(scope, gallery) do
    [
      status_label(gallery.status),
      "#{gallery.media_count} #{if gallery.media_count == 1, do: "photo", else: "photos"}",
      size(gallery.bytes_total),
      window_line(scope, gallery)
    ]
    |> Enum.join(" · ")
  end

  @doc "How long the client can still get in, or that the window has not opened."
  def window_line(_scope, %{expires_at: nil}), do: "Not delivered yet"

  def window_line(scope, gallery),
    do: "Live until #{Formats.date(scope, gallery.expires_at)}"

  @doc "The URL a thumbnail is served from — the derivative if there is one."
  def thumb_url(media), do: Storage.url(media.thumb_key || media.storage_key)

  @doc "The client-facing address of a share link, shown once with its token."
  def share_url(token), do: url(~p"/g/#{token}")

  @doc "Why an upload was refused, in the browser's own words."
  def upload_error(:too_large), do: "Larger than 100 MB"
  def upload_error(:too_many_files), do: "Too many at once — #{@max_entries} is the limit"
  def upload_error(:not_accepted), do: "Not an image or video"
  def upload_error(other), do: to_string(other)

  def max_entries, do: @max_entries
end
