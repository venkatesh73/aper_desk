defmodule AperDeskWeb.PackagesLive do
  @moduledoc """
  What the studio sells: name, price, what is included, how long it takes.

  Packages are archived, never deleted. A quote issued last month names the
  package it was built from, and deleting the row would turn that quote's
  provenance into a dangling id.

  Prices are entered in major units and converted here, because nobody types
  450000 for four and a half thousand. The conversion happens once, at this
  boundary; everything below it is integer minor units.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Catalog
  alias AperDesk.Catalog.{Package, PackageMedia}
  alias AperDesk.Crm.Lead
  alias AperDesk.Money
  alias AperDesk.Storage

  # Two uploads rather than one, because LiveView's `max_file_size` is a
  # property of the upload and the two kinds have different limits. Splitting
  # them is what lets the browser refuse an oversized file before it is sent
  # — one combined upload could only enforce the larger cap, and a 9 MB JPEG
  # would travel all the way to the server to be rejected there.
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(show_archived: false)
     |> allow_upload(:images,
       accept: Enum.map(Storage.image_extensions(), &".#{&1}"),
       max_entries: Catalog.media_limit(),
       max_file_size: PackageMedia.max_bytes("image")
     )
     |> allow_upload(:videos,
       accept: Enum.map(Storage.video_extensions(), &".#{&1}"),
       max_entries: Catalog.media_limit(),
       max_file_size: PackageMedia.max_bytes("video")
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: "Packages")
    |> load_packages()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "New package")
    |> assign(package: %Package{media: []})
    # Tracked separately: price is typed in major units, which is not a schema
    # field. Rendering it from the struct reset the box on every keystroke, so
    # the package saved with no price at all.
    |> assign(price_major: nil)
    |> assign(form: to_form(Catalog.change_package(), as: :package))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Catalog.fetch_package(socket.assigns.current_scope, id) do
      {:ok, package} ->
        socket
        |> assign(page_title: "Edit #{package.name}")
        |> assign(package: package)
        |> assign(price_major: price_major(package))
        |> assign(form: to_form(Catalog.change_package(package), as: :package))

      {:error, _reason} ->
        socket
        |> put_flash(:error, "That package could not be found.")
        |> push_navigate(to: ~p"/app/packages")
    end
  end

  @impl true
  def handle_event("toggle-archived", _params, socket) do
    {:noreply,
     socket |> assign(show_archived: not socket.assigns.show_archived) |> load_packages()}
  end

  def handle_event("validate", %{"package" => params}, socket) do
    changeset =
      socket.assigns.package
      |> Catalog.change_package(to_cents(params, socket.assigns.current_scope))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(form: to_form(changeset, as: :package))
     |> assign(price_major: params["price_major"] || socket.assigns.price_major)}
  end

  def handle_event("save", %{"package" => params}, socket) do
    scope = socket.assigns.current_scope
    params = Map.put_new(params, "price_major", socket.assigns.price_major)
    attrs = to_cents(params, scope)

    result =
      case socket.assigns.live_action do
        :new -> Catalog.create_package(scope, attrs)
        :edit -> Catalog.update_package(scope, socket.assigns.package.id, attrs)
      end

    case result do
      {:ok, _package} ->
        {:noreply,
         socket
         |> put_flash(:info, "Package saved.")
         |> push_navigate(to: ~p"/app/packages")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :package))}

      {:error, {:limit_reached, _key, used, limit}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Your plan allows #{limit} packages and you have #{used}. Archive one or move up a plan."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  def handle_event("validate-media", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref, "upload" => upload}, socket),
    do: {:noreply, cancel_upload(socket, String.to_existing_atom(upload), ref)}

  def handle_event("upload-media", _params, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.package

    results =
      Enum.flat_map([:images, :videos], fn upload ->
        consume_uploaded_entries(socket, upload, fn %{path: path}, entry ->
          {:ok, store(scope, package, path, entry)}
        end)
      end)

    {added, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

    {:noreply,
     socket
     |> reload_package()
     |> flash_for(added, failed)}
  end

  def handle_event("remove-media", %{"id" => id}, socket) do
    case Catalog.remove_media(socket.assigns.current_scope, id) do
      {:ok, _media} ->
        {:noreply, socket |> reload_package() |> put_flash(:info, "Removed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove it: #{inspect(reason)}")}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    case Catalog.archive_package(socket.assigns.current_scope, id) do
      {:ok, package} ->
        {:noreply, socket |> put_flash(:info, "#{package.name} archived.") |> load_packages()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not archive: #{inspect(reason)}")}
    end
  end

  def handle_event("restore", %{"id" => id}, socket) do
    case Catalog.restore_package(socket.assigns.current_scope, id) do
      {:ok, package} ->
        {:noreply, socket |> put_flash(:info, "#{package.name} restored.") |> load_packages()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not restore: #{inspect(reason)}")}
    end
  end

  ## Internals

  defp load_packages(socket) do
    packages =
      Catalog.list_packages(socket.assigns.current_scope,
        include_archived: socket.assigns.show_archived
      )

    assign(socket, packages: packages)
  end

  ## Sample work

  # The file is written before the row, for the reason spelled out in
  # `Galleries.add_media/3`: an orphan costs disk until a sweep finds it, while
  # a row with no file behind it is a broken image on the shopfront. If the row
  # is refused — over the count, or over the size cap — the object is taken
  # back out immediately rather than waiting for that sweep.
  defp store(scope, package, path, entry) do
    kind = Storage.kind_of(entry.client_type, entry.client_name)
    key = Storage.key_in(Storage.package_prefix(package.studio_id, package.id), entry.client_name)

    with {:ok, key} <- Storage.put(key, path, content_type: entry.client_type),
         {:ok, media} <-
           Catalog.add_media(scope, package.id, %{
             "kind" => kind,
             "storage_key" => key,
             "url" => Storage.url(key),
             "filename" => entry.client_name,
             "content_type" => entry.client_type,
             "byte_size" => byte_size_on_disk(path, entry),
             "alt" => package.name
           }) do
      {:ok, media}
    else
      {:error, reason} ->
        Storage.delete(key)
        {:error, reason}
    end
  end

  # What the browser claimed is a hint; what landed on disk is the file. The
  # size cap is checked against the second, so a doctored `client_size` cannot
  # walk a 40 MB video past a 10 MB limit.
  defp byte_size_on_disk(path, entry) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > 0 -> size
      _ -> entry.client_size || 0
    end
  end

  defp flash_for(socket, added, []) when added != [],
    do: put_flash(socket, :info, "#{length(added)} added.")

  defp flash_for(socket, [], failed) when failed != [],
    do: put_flash(socket, :error, refusal(failed))

  defp flash_for(socket, added, failed) when added != [] and failed != [],
    do: put_flash(socket, :error, "#{length(added)} added. #{refusal(failed)}")

  defp flash_for(socket, _added, _failed), do: socket

  defp refusal(failed) do
    case Enum.find_value(failed, fn {:error, reason} -> reason end) do
      {:media_limit, limit} ->
        "#{length(failed)} refused: a package shows at most #{limit} pieces of work."

      %Ecto.Changeset{} = changeset ->
        "#{length(failed)} refused: #{first_error(changeset)}"

      _other ->
        "#{length(failed)} could not be stored."
    end
  end

  defp first_error(%Ecto.Changeset{errors: [{field, {message, _}} | _]}),
    do: "#{field |> to_string() |> String.replace("_", " ")} #{message}"

  defp first_error(_changeset), do: "it would not save"

  defp reload_package(socket) do
    case Catalog.fetch_package(socket.assigns.current_scope, socket.assigns.package.id) do
      {:ok, package} -> assign(socket, package: package)
      _ -> socket
    end
  end

  # Prices are typed in major units. The conversion happens once, here, and
  # everything below this line is integer minor units — see `AperDesk.Money`.
  defp to_cents(params, scope) do
    currency = params["price_currency"] || scope.currency

    case params["price_major"] do
      nil ->
        params

      "" ->
        Map.put(params, "price_cents", 0)

      major ->
        params
        |> Map.put("price_cents", Money.from_major(major, currency))
        |> Map.put("price_currency", currency)
    end
  end

  ## Presentation

  def shoot_types, do: Lead.shoot_types()

  def humanise(value), do: value |> String.replace("_", " ") |> String.capitalize()

  def price(package), do: package |> Package.price() |> Money.to_string()

  def deposit(package), do: package |> Package.deposit() |> Money.to_string()

  @doc "The price in major units, for the form field."
  def price_major(%Package{price_cents: nil}), do: nil

  def price_major(%Package{price_cents: cents, price_currency: currency}),
    do: Money.to_major(cents, currency || "USD")

  @doc "The size caps, for the upload control's own copy."
  def max_label(kind), do: PackageMedia.max_label(kind)

  def media_limit, do: Catalog.media_limit()

  @doc """
  Where the file is served from.

  Computed from the key rather than read from the stored `url`. The stored one
  is a snapshot of wherever the bucket pointed the day it was written, so a
  move to a different CDN would leave every older row pointing at nothing.
  """
  def media_url(%PackageMedia{storage_key: nil} = media), do: media.url
  def media_url(%PackageMedia{} = media), do: Storage.url(media.storage_key)

  @doc "Why the browser refused a file, in its own words."
  def upload_error(:too_large, kind), do: "Larger than #{max_label(kind)}"
  def upload_error(:too_many_files, _kind), do: "More than #{media_limit()} at once"
  def upload_error(:not_accepted, "video"), do: "Not a video file"
  def upload_error(:not_accepted, _kind), do: "Not an image file"
  def upload_error(other, _kind), do: to_string(other)

  @doc "Bytes as a person would say them."
  def size(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def size(bytes) when is_integer(bytes) and bytes >= 1024, do: "#{div(bytes, 1024)} KB"
  def size(bytes) when is_integer(bytes), do: "#{bytes} B"
  def size(_bytes), do: "0 B"

  def duration(%Package{duration_minutes: nil}), do: "—"
  def duration(%Package{duration_minutes: minutes}) when minutes < 60, do: "#{minutes} min"

  def duration(%Package{duration_minutes: minutes}) do
    hours = div(minutes, 60)
    rest = rem(minutes, 60)
    if rest == 0, do: "#{hours} h", else: "#{hours} h #{rest} min"
  end
end
