defmodule AperDeskWeb.LeadLive do
  @moduledoc """
  One lead: the detail page, and the form that creates a new one.

  Both stage moves and the reply stamp go through `AperDesk.Crm`, so the domain
  event they emit is the same one an API call would produce. A screen that
  updated the row directly would be invisible to every workflow watching for it.

  The readiness list is the point of the detail page: it says what is still
  missing before this enquiry can become a booking, rather than leaving someone
  to work that out from a form full of blanks.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Automation
  alias AperDesk.Crm
  alias AperDesk.Crm.Lead
  alias AperDesk.Formats
  alias AperDesk.Money
  alias AperDeskWeb.Graphql.Resolvers.Helpers

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns.current_scope

    socket
    |> assign(page_title: "New lead")
    |> assign(lead: %Lead{})
    |> assign(contacts: contacts(scope))
    |> assign(custom_fields: Crm.list_custom_fields(scope))
    # Budget is typed in major units, which is not a schema field, so it is
    # carried across re-renders here rather than read back from the struct.
    |> assign(budget_major: nil)
    |> assign(form: to_form(Crm.change_lead(), as: :lead))
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case Crm.fetch_lead_detail(scope, id) do
      {:ok, lead} ->
        socket
        |> assign(page_title: display_name(lead))
        |> assign(lead: lead)
        |> assign(tags: Crm.tags_for(scope, lead))
        |> assign(
          activity:
            Automation.activity(scope, subject_type: "Lead", subject_id: lead.id, limit: 30)
        )

      {:error, _reason} ->
        socket
        |> put_flash(:error, "That lead could not be found.")
        |> push_navigate(to: ~p"/app/leads")
    end
  end

  @impl true
  def handle_event("validate", %{"lead" => params}, socket) do
    changeset =
      socket.assigns.lead
      |> Crm.change_lead(to_minor(params, socket.assigns.current_scope))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(form: to_form(changeset, as: :lead))
     |> assign(budget_major: params["budget_major"] || socket.assigns.budget_major)}
  end

  def handle_event("save", %{"lead" => params}, socket) do
    params =
      params
      |> Map.put_new("budget_major", socket.assigns.budget_major)
      |> to_minor(socket.assigns.current_scope)

    case Crm.create_lead(socket.assigns.current_scope, params) do
      {:ok, lead} ->
        {:noreply,
         socket
         |> put_flash(:info, "Lead created.")
         |> push_navigate(to: ~p"/app/leads/#{lead}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :lead))}

      {:error, {:limit_reached, _key, used, limit}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Your plan allows #{limit} active leads and you have #{used}. Archive one or move up a plan."
         )}

      {:error, {:invalid_custom_fields, errors}} ->
        {:noreply, put_flash(socket, :error, "Check the custom fields: #{describe(errors)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create the lead: #{inspect(reason)}")}
    end
  end

  def handle_event("move", %{"stage" => stage}, socket) do
    case Crm.move_lead(socket.assigns.current_scope, socket.assigns.lead.id, stage) do
      {:ok, _lead} ->
        {:noreply,
         socket
         |> put_flash(:info, "Moved to #{humanise(stage)}.")
         |> apply_action(:show, %{"id" => socket.assigns.lead.id})}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, "Marking a lead lost needs a reason. Use the lost button.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not move the lead: #{inspect(reason)}")}
    end
  end

  def handle_event("lose", %{"lost" => %{"reason" => reason}}, socket) do
    scope = socket.assigns.current_scope

    case Crm.move_lead(scope, socket.assigns.lead.id, "lost", %{lost_reason: reason}) do
      {:ok, _lead} ->
        {:noreply,
         socket
         |> put_flash(:info, "Marked lost.")
         |> apply_action(:show, %{"id" => socket.assigns.lead.id})}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Give a reason so the pipeline stays honest.")}
    end
  end

  def handle_event("replied", _params, socket) do
    case Crm.record_reply(socket.assigns.current_scope, socket.assigns.lead.id) do
      {:ok, _lead} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reply recorded. The clock has stopped.")
         |> apply_action(:show, %{"id" => socket.assigns.lead.id})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not record that: #{inspect(reason)}")}
    end
  end

  ## Data

  # Budgets are typed the way people say them. The conversion to minor units
  # happens once, here, and everything below this line is integer cents.
  defp to_minor(params, scope) do
    currency = params["budget_currency"] || scope.currency

    case params["budget_major"] do
      nil ->
        params

      "" ->
        Map.drop(params, ["budget_major"])

      major ->
        exponent = Money.exponent(currency)

        cents =
          case Float.parse(to_string(major)) do
            {value, _rest} -> round(value * :math.pow(10, exponent))
            :error -> nil
          end

        params
        |> Map.drop(["budget_major"])
        |> Map.put("budget_cents", cents)
        |> Map.put("budget_currency", currency)
    end
  end

  @doc "Contacts as combobox options, with the email as the searchable detail."
  def contact_options(contacts),
    do: Enum.map(contacts, &{&1.name, &1.id, &1.email})

  defp contacts(scope) do
    case Crm.list_contacts(scope, limit: 200) do
      {:ok, contacts} -> Enum.reject(contacts, & &1.archived_at)
      _ -> []
    end
  end

  defp describe(errors) when is_list(errors),
    do: Enum.map_join(errors, ", ", fn {field, message} -> "#{field} #{message}" end)

  ## Presentation

  def stages, do: Lead.stages()
  def shoot_types, do: Lead.shoot_types()
  def sources, do: Lead.sources()

  def humanise(value), do: value |> String.replace("_", " ") |> String.capitalize()

  def display_name(lead), do: (lead.contact && lead.contact.name) || lead.title

  def value(lead) do
    case Money.from_fields(lead, :estimated_value) || Money.from_fields(lead, :budget) do
      nil -> nil
      money -> Money.to_string(money)
    end
  end

  def overdue?(lead), do: Lead.overdue?(lead, DateTime.utc_now())

  def time_ago(at), do: Helpers.time_ago(at)

  def shoot_date(scope, lead), do: Formats.relative_date(scope, lead.desired_date)

  @doc """
  What is still missing before this enquiry can become a booking.

  Ordered by what blocks progress soonest, so the top of the list is the next
  thing to do rather than a checklist to read in full.
  """
  def readiness(lead) do
    [
      %{label: "First reply sent", done: not is_nil(lead.first_responded_at)},
      %{label: "Contact details", done: not is_nil(lead.contact_id)},
      %{label: "Shoot date", done: not is_nil(lead.desired_date)},
      %{label: "Venue", done: present?(lead.location)},
      %{label: "Budget", done: not is_nil(lead.budget_cents)}
    ]
  end

  @doc "The next stage along the pipeline, or nil at the end."
  def next_stage(%Lead{stage: stage}) do
    open = ~w(new contacted consult quote_sent booked)

    case Enum.find_index(open, &(&1 == stage)) do
      nil -> nil
      index -> Enum.at(open, index + 1)
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
