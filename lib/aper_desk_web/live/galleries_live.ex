defmodule AperDeskWeb.GalleriesLive do
  @moduledoc """
  Every gallery the studio has, and the form that starts a new one.

  The card for each gallery answers the question a photographer actually has
  when they open this screen — *what does this one still need from me?* — so
  the second line is the count and the third is whatever is outstanding: a
  delivery not yet made, a window about to close, a recovery period running
  out. Nothing here is decoration; a card with nothing outstanding says so.

  Storage sits in the top bar rather than a settings page because it is the
  plan's pricing lever, and the moment to notice it is filling up is while
  looking at the things filling it.
  """

  use AperDeskWeb, :live_view

  import Ecto.Query
  import AperDeskWeb.AppComponents

  alias AperDesk.Billing
  alias AperDesk.Crm
  alias AperDesk.Formats
  alias AperDesk.Galleries
  alias AperDesk.Galleries.{Gallery, GalleryMedia}
  alias AperDesk.Repo
  alias AperDesk.Scoped

  @statuses ~w(draft ready delivered archived)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, status: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: "Galleries")
    |> assign(usage: usage(socket.assigns.current_scope))
    |> load_galleries()
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns.current_scope

    socket
    |> assign(page_title: "New gallery")
    |> assign(contacts: contacts(scope))
    |> assign(form: to_form(Gallery.changeset(%Gallery{}, %{}), as: :gallery))
  end

  @impl true
  def handle_event("status", %{"status" => status}, socket) do
    status = if status == "", do: nil, else: status
    {:noreply, socket |> assign(status: status) |> load_galleries()}
  end

  def handle_event("validate", %{"gallery" => params}, socket) do
    changeset =
      %Gallery{}
      |> Gallery.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :gallery))}
  end

  def handle_event("save", %{"gallery" => params}, socket) do
    case Galleries.create_gallery(socket.assigns.current_scope, params) do
      {:ok, gallery} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{gallery.title} created. Upload the photographs next.")
         |> push_navigate(to: ~p"/app/galleries/#{gallery}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(retitle(changeset), as: :gallery))}

      {:error, {:limit_reached, _key, limit}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Your plan allows #{limit} active galleries. Archive one, or move up a plan."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create it: #{inspect(reason)}")}
    end
  end

  # The slug is derived from the title and is not a field on this form, and the
  # composite unique index reports itself against `:studio_id`, which is not a
  # field either — so a collision would land on two controls the reader cannot
  # see, and pressing the button would appear to do nothing. Two galleries
  # called "Smith wedding" is an ordinary thing for a studio to want, so the
  # message has to say what to do about it.
  @slug_index "galleries_studio_id_slug_index"

  defp retitle(%Ecto.Changeset{} = changeset) do
    {collisions, rest} =
      Enum.split_with(changeset.errors, fn {_field, {_message, opts}} ->
        opts[:constraint_name] == @slug_index
      end)

    case collisions do
      [] ->
        changeset

      _ ->
        changeset
        |> Map.put(:errors, rest)
        |> Ecto.Changeset.add_error(
          :title,
          "is already used by another gallery — add the year, or the venue"
        )
    end
  end

  ## Data

  defp load_galleries(socket) do
    scope = socket.assigns.current_scope
    opts = if socket.assigns.status, do: [status: socket.assigns.status], else: []

    galleries =
      case Galleries.list_galleries(scope, opts) do
        {:ok, list} -> list
        _ -> []
      end

    socket
    |> assign(galleries: galleries)
    |> assign(covers: covers(scope, galleries))
  end

  # One query for every cover rather than one per card. A studio with forty
  # galleries on screen is forty round trips otherwise, for a thumbnail.
  defp covers(scope, galleries) do
    ids = galleries |> Enum.map(& &1.cover_media_id) |> Enum.reject(&is_nil/1)

    if ids == [] do
      %{}
    else
      GalleryMedia
      |> Scoped.for_studio(scope)
      |> where([m], m.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, AperDesk.Storage.url(&1.thumb_key || &1.storage_key)})
    end
  end

  defp usage(scope) do
    case Billing.usage(scope) do
      {:ok, usage} -> Enum.find(usage.meters, &(&1.key == "storage_bytes"))
      _ -> nil
    end
  end

  defp contacts(scope) do
    case Crm.list_contacts(scope, limit: 200) do
      {:ok, contacts} -> contacts
      _ -> []
    end
  end

  ## Presentation

  def statuses, do: @statuses

  def status_label("draft"), do: "Editing"
  def status_label("ready"), do: "Ready to deliver"
  def status_label("delivered"), do: "Delivered"
  def status_label("archived"), do: "Archived"
  def status_label(other), do: String.capitalize(other)

  def status_tone("delivered"), do: "ok"
  def status_tone("ready"), do: "warn"
  def status_tone("archived"), do: "bad"
  def status_tone(_other), do: ""

  @doc "The count line: what is in the gallery, in units a person reads."
  def contents(%Gallery{media_count: 0}), do: "No photographs yet"

  def contents(%Gallery{} = gallery) do
    "#{gallery.media_count} #{if gallery.media_count == 1, do: "photo", else: "photos"} · #{size(gallery.bytes_total)}"
  end

  @doc """
  What this gallery still needs, or that it needs nothing.

  A card that cannot say anything useful says "Nothing outstanding" rather than
  going blank, so the row keeps its height and the eye can skip it.
  """
  def outstanding(scope, gallery, today \\ nil)

  def outstanding(_scope, %Gallery{status: "draft", media_count: 0}, _today),
    do: "Waiting on the upload"

  def outstanding(_scope, %Gallery{status: "draft"}, _today), do: "Not delivered yet"

  def outstanding(_scope, %Gallery{status: "ready"}, _today), do: "Ready — send it to the client"

  def outstanding(_scope, %Gallery{status: "archived"} = gallery, today) do
    case days_until(gallery.purge_after, today) do
      nil -> "Archived"
      days when days <= 0 -> "Recovery window has passed"
      days -> "Recoverable for #{days} more #{plural_days(days)}"
    end
  end

  def outstanding(scope, %Gallery{status: "delivered"} = gallery, today) do
    case days_until(gallery.expires_at, today) do
      nil -> "Delivered"
      days when days <= 0 -> "Window has closed"
      days when days <= 14 -> "Archives in #{days} #{plural_days(days)}"
      _ -> "Live until #{Formats.date(scope, gallery.expires_at)}"
    end
  end

  def outstanding(_scope, _gallery, _today), do: "Nothing outstanding"

  @doc "A tone for the outstanding line, so a closing window reads as urgent."
  def outstanding_tone(%Gallery{status: "archived"}), do: "bad"

  def outstanding_tone(%Gallery{status: "delivered"} = gallery) do
    case days_until(gallery.expires_at, nil) do
      days when is_integer(days) and days <= 14 -> "bad"
      _ -> ""
    end
  end

  def outstanding_tone(_gallery), do: ""

  @doc "Bytes as a person would say them."
  def size(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{trim(bytes / 1_073_741_824)} GB"

  def size(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{trim(bytes / 1_048_576)} MB"

  def size(bytes) when is_integer(bytes) and bytes >= 1024, do: "#{trim(bytes / 1024)} KB"
  def size(bytes) when is_integer(bytes), do: "#{bytes} B"
  def size(_bytes), do: "0 B"

  @doc "The storage meter's caption, or nil when the plan is unmetered."
  def storage_caption(nil), do: nil
  def storage_caption(%{limit: :unlimited}), do: nil

  def storage_caption(%{used: used, limit: limit}),
    do: "#{size(used)} of #{size(limit)} live"

  @doc "The meter's fill, clamped so an over-limit studio does not overflow the bar."
  def storage_fill(%{utilisation: value}) when is_float(value),
    do: "#{min(round(value * 100), 100)}%"

  def storage_fill(_meter), do: "0%"

  defp trim(value) do
    rounded = Float.round(value, 1)
    if rounded == Float.round(rounded), do: round(rounded), else: rounded
  end

  defp days_until(nil, _today), do: nil

  defp days_until(%DateTime{} = at, _today),
    do: DateTime.diff(at, DateTime.utc_now(), :day)

  defp plural_days(1), do: "day"
  defp plural_days(_), do: "days"

  def contact_options(contacts), do: Enum.map(contacts, &{&1.name, &1.id, &1.email})
end
