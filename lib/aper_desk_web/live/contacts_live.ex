defmodule AperDeskWeb.ContactsLive do
  @moduledoc """
  The address book: every person or company the studio deals with.

  One LiveView serves the list, the detail page and both forms, because they
  share the same data and the same permission check — splitting them into four
  modules would mean four copies of the loading and authorisation code.

  Contacts are archived, never deleted. A contact is referenced by every lead,
  job and invoice they appear on, and removing the row would turn all of that
  history into a blank.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Crm
  alias AperDesk.Crm.Contact
  alias AperDesk.Formats

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, query: "", show_archived: false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: "Contacts")
    |> load_contacts()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "New contact")
    |> assign(contact: %Contact{})
    |> assign(form: to_form(Crm.change_contact(), as: :contact))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Crm.fetch_contact(socket.assigns.current_scope, id) do
      {:ok, contact} ->
        socket
        |> assign(page_title: "Edit #{contact.name}")
        |> assign(contact: contact)
        |> assign(form: to_form(Crm.change_contact(contact), as: :contact))

      {:error, _reason} ->
        not_found(socket)
    end
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case Crm.fetch_contact(scope, id) do
      {:ok, contact} ->
        {:ok, leads} = Crm.list_leads(scope, limit: 100)

        socket
        |> assign(page_title: contact.name)
        |> assign(contact: contact)
        |> assign(leads: Enum.filter(leads, &(&1.contact_id == contact.id)))
        |> assign(tags: Crm.tags_for(scope, contact))

      {:error, _reason} ->
        not_found(socket)
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(query: query) |> load_contacts()}
  end

  def handle_event("toggle-archived", _params, socket) do
    {:noreply,
     socket
     |> assign(show_archived: not socket.assigns.show_archived)
     |> load_contacts()}
  end

  def handle_event("validate", %{"contact" => params}, socket) do
    changeset =
      socket.assigns.contact
      |> Crm.change_contact(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :contact))}
  end

  def handle_event("save", %{"contact" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  def handle_event("archive", %{"id" => id}, socket) do
    case Crm.archive_contact(socket.assigns.current_scope, id) do
      {:ok, contact} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{contact.name} archived.")
         |> push_navigate(to: ~p"/app/contacts")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, describe(reason))}
    end
  end

  def handle_event("restore", %{"id" => id}, socket) do
    case Crm.restore_contact(socket.assigns.current_scope, id) do
      {:ok, contact} ->
        {:noreply, socket |> put_flash(:info, "#{contact.name} restored.") |> load_contacts()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, describe(reason))}
    end
  end

  ## Internals

  defp save(socket, :new, params) do
    case Crm.create_contact(socket.assigns.current_scope, params) do
      {:ok, contact} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{contact.name} added.")
         |> push_navigate(to: ~p"/app/contacts/#{contact}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :contact))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, describe(reason))}
    end
  end

  defp save(socket, :edit, params) do
    case Crm.update_contact(socket.assigns.current_scope, socket.assigns.contact.id, params) do
      {:ok, contact} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved.")
         |> push_navigate(to: ~p"/app/contacts/#{contact}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :contact))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, describe(reason))}
    end
  end

  defp load_contacts(socket) do
    scope = socket.assigns.current_scope

    opts = [
      query: socket.assigns.query,
      include_archived: socket.assigns.show_archived,
      limit: 100
    ]

    case Crm.list_contacts(scope, opts) do
      {:ok, contacts} ->
        assign(socket, contacts: contacts, denied: false)

      {:error, :unauthorized} ->
        assign(socket, contacts: [], denied: true)
    end
  end

  defp not_found(socket) do
    socket
    |> put_flash(:error, "That contact could not be found.")
    |> push_navigate(to: ~p"/app/contacts")
  end

  defp describe(:unauthorized), do: "You do not have permission to do that."
  defp describe(:not_found), do: "That contact could not be found."
  defp describe(other), do: "Something went wrong: #{inspect(other)}"

  ## Presentation

  @doc "Channels a client can be reached on."
  def channels, do: ~w(email phone whatsapp sms)

  def channel_label(channel), do: channel |> String.replace("_", " ") |> String.capitalize()

  def added_on(scope, contact), do: Formats.date(scope, contact.inserted_at)
end
