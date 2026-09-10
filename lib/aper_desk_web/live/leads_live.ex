defmodule AperDeskWeb.LeadsLive do
  @moduledoc """
  The lead pipeline, as a board or a table.

  Stage moves go through `Crm.move_lead/4`, which commits the change and its
  domain event together — so dragging a lead to "booked" fires the booking
  workflow through the same path an API call would, rather than a UI-only
  shortcut that automation never hears about.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Crm
  alias AperDesk.Crm.Lead
  alias AperDesk.Formats
  alias AperDesk.Money

  @board_stages ~w(new contacted consult quote_sent booked)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Leads", view: :board, stage_filter: nil, query: "")
     |> load_leads()}
  end

  @impl true
  def handle_event("set-view", %{"view" => view}, socket) when view in ~w(board table) do
    {:noreply, assign(socket, view: String.to_existing_atom(view))}
  end

  def handle_event("filter", %{"query" => query}, socket) do
    {:noreply, socket |> assign(query: query) |> load_leads()}
  end

  def handle_event("move", %{"id" => id, "stage" => stage}, socket) do
    case Crm.move_lead(socket.assigns.current_scope, id, stage) do
      {:ok, _lead} ->
        {:noreply,
         socket |> put_flash(:info, "Lead moved to #{humanise(stage)}.") |> load_leads()}

      {:error, %Ecto.Changeset{}} ->
        # Losing a lead requires a reason, which the board cannot collect — so
        # it sends the user to the lead where they can give one.
        {:noreply,
         socket
         |> put_flash(:error, "That move needs more detail. Open the lead to complete it.")
         |> load_leads()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not move the lead: #{inspect(reason)}")}
    end
  end

  ## Data

  defp load_leads(socket) do
    scope = socket.assigns.current_scope
    opts = [archived: false, limit: 100]

    case Crm.list_leads(scope, opts) do
      {:ok, leads} ->
        leads = filter(leads, socket.assigns.query)

        socket
        |> assign(leads: leads)
        |> assign(columns: columns(leads))
        |> assign(denied: false)

      {:error, :unauthorized} ->
        socket |> assign(leads: [], columns: [], denied: true)
    end
  end

  defp filter(leads, query) when query in [nil, ""], do: leads

  defp filter(leads, query) do
    needle = String.downcase(query)

    Enum.filter(leads, fn lead ->
      haystack =
        [
          lead.title,
          lead.location,
          lead.contact && lead.contact.name,
          lead.contact && lead.contact.email
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
        |> String.downcase()

      String.contains?(haystack, needle)
    end)
  end

  defp columns(leads) do
    grouped = Enum.group_by(leads, & &1.stage)

    for stage <- @board_stages do
      %{stage: stage, label: humanise(stage), leads: Map.get(grouped, stage, [])}
    end
  end

  ## Presentation helpers used by the template

  def board_stages, do: @board_stages

  def humanise(stage), do: stage |> String.replace("_", " ") |> String.capitalize()

  def display_name(lead), do: (lead.contact && lead.contact.name) || lead.title

  def value(lead) do
    case Money.from_fields(lead, :estimated_value) || Money.from_fields(lead, :budget) do
      nil -> nil
      money -> Money.to_string(money)
    end
  end

  @doc "The shoot date, in the studio's own format."
  def date_label(scope, lead), do: Formats.relative_date(scope, lead.desired_date)

  def overdue?(lead), do: Lead.overdue?(lead, DateTime.utc_now())

  @doc "The stage a lead can be nudged to next, or nil at the end of the pipeline."
  def next_stage(%Lead{stage: stage}) do
    case Enum.find_index(@board_stages, &(&1 == stage)) do
      nil -> nil
      index -> Enum.at(@board_stages, index + 1)
    end
  end
end
