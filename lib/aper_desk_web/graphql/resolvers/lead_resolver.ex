defmodule AperDeskWeb.Graphql.Resolvers.LeadResolver do
  @moduledoc """
  Resolves leads into the shape the client renders.

  The presentational fields — `next_action`, `date_status`, `readiness` — are
  computed here rather than in the app, so the mobile client and the LiveView
  UI cannot disagree about whether a lead is overdue.
  """

  alias AperDesk.Automation
  alias AperDesk.Crm
  alias AperDesk.Crm.Lead
  alias AperDesk.Repo
  alias AperDeskWeb.Graphql.Resolvers.Helpers

  @stage_labels %{
    "new" => "New",
    "contacted" => "Contacted",
    "consult" => "Consult",
    "quote_sent" => "Quote sent",
    "booked" => "Booked",
    "completed" => "Completed",
    "lost" => "Lost"
  }

  def list(_parent, args, %{context: %{scope: scope}}) do
    opts =
      []
      |> maybe(:stage, args[:stage])
      |> maybe(:shoot_type, args[:type])
      |> maybe(:owner_id, args[:assigned_to])

    with {:ok, leads} <- Crm.list_leads(scope, opts) do
      {:ok, leads |> filter_search(args[:search]) |> Enum.map(&summary/1)}
    end
  end

  def get(_parent, %{id: id}, %{context: %{scope: scope}}) do
    with {:ok, lead} <- Crm.fetch_lead(scope, id) do
      lead = Repo.preload(lead, [:contact, :owner])

      activity =
        Automation.activity(scope, subject_type: "Lead", subject_id: lead.id, limit: 20)

      {:ok,
       lead
       |> summary()
       |> Map.merge(%{
         package_summary: nil,
         readiness: readiness(lead),
         activity:
           Enum.map(activity, &%{time: Helpers.time_ago(&1.occurred_at), text: &1.summary})
       })}
    end
  end

  def pipeline(_parent, _args, %{context: %{scope: scope}}) do
    with {:ok, leads} <- Crm.list_leads(scope, archived: false, limit: 100) do
      grouped = Enum.group_by(leads, & &1.stage)

      {:ok,
       for stage <- Lead.stages(), stage not in ["completed"] do
         stage_leads = Map.get(grouped, stage, [])

         %{
           stage: stage,
           label: Map.get(@stage_labels, stage, stage),
           count: length(stage_leads),
           cards: Enum.map(stage_leads, &card/1)
         }
       end}
    end
  end

  def create(_parent, %{input: input}, %{context: %{scope: scope}}) do
    attrs = %{
      "title" => input.name,
      "shoot_type" => input[:shoot_type] || "other",
      "desired_date" => parse_date(input[:shoot_date]),
      "location" => input[:venue],
      "guest_count" => input[:guests],
      "source" => input[:source] || "manual",
      "owner_id" => input[:assigned_to],
      "budget_cents" => to_cents(input[:budget_usd]),
      "budget_currency" => scope.currency
    }

    case Crm.create_lead(scope, attrs) do
      {:ok, lead} -> {:ok, %{lead: summary(lead), errors: []}}
      {:error, %Ecto.Changeset{} = cs} -> {:ok, %{lead: nil, errors: errors(cs)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_stage(_parent, %{id: id, stage: stage}, %{context: %{scope: scope}}) do
    case Crm.move_lead(scope, id, stage) do
      {:ok, lead} -> {:ok, %{lead: summary(lead), errors: []}}
      {:error, %Ecto.Changeset{} = cs} -> {:ok, %{lead: nil, errors: errors(cs)}}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Shaping

  defp summary(%Lead{} = lead) do
    lead = Repo.preload(lead, [:contact, :owner])
    today = Date.utc_today()

    %{
      id: lead.id,
      name: (lead.contact && lead.contact.name) || lead.title,
      subtitle: lead.title,
      email: lead.contact && lead.contact.email,
      phone: lead.contact && lead.contact.phone,
      shoot_type: lead.shoot_type,
      shoot_date: lead.desired_date && Date.to_iso8601(lead.desired_date),
      shoot_date_label: Helpers.date_label(lead.desired_date, today),
      date_status: Helpers.date_status(lead.desired_date, today),
      venue: lead.location,
      guests: lead.guest_count,
      source: lead.source,
      stage: lead.stage,
      budget_usd: Helpers.to_major(lead.budget_cents, lead.budget_currency || "USD"),
      next_action: next_action(lead),
      next_action_tone: next_action_tone(lead),
      assignee: lead.owner,
      hero_image_url: nil
    }
  end

  defp card(%Lead{} = lead) do
    lead = Repo.preload(lead, [:contact, :owner])
    overdue? = Lead.overdue?(lead, DateTime.utc_now())

    %{
      id: lead.id,
      title: (lead.contact && lead.contact.name) || lead.title,
      meta: Helpers.date_label(lead.desired_date),
      amount_usd: Helpers.to_major(lead.estimated_value_cents || lead.budget_cents, "USD"),
      initials: Helpers.initials(lead.owner && lead.owner.name),
      badge: Helpers.humanise(lead.shoot_type),
      badge_tone: :neutral,
      trailing: if(overdue?, do: "Overdue", else: nil),
      flag: if(overdue?, do: "overdue", else: nil)
    }
  end

  # The one thing the studio should do next. Ordered by urgency, because a
  # list of everything outstanding is the same as no guidance at all.
  defp next_action(%Lead{} = lead) do
    cond do
      Lead.overdue?(lead, DateTime.utc_now()) -> "Reply now — past the SLA"
      is_nil(lead.first_responded_at) -> "Send first reply"
      lead.stage == "new" -> "Qualify the enquiry"
      lead.stage == "contacted" -> "Book a consult"
      lead.stage == "consult" -> "Send a quote"
      lead.stage == "quote_sent" -> "Chase the quote"
      lead.stage == "booked" -> "Confirm the shoot details"
      true -> nil
    end
  end

  defp next_action_tone(%Lead{} = lead) do
    cond do
      Lead.overdue?(lead, DateTime.utc_now()) -> :critical
      is_nil(lead.first_responded_at) -> :warning
      true -> :neutral
    end
  end

  defp readiness(%Lead{} = lead) do
    [
      %{label: "Contact details", detail: nil, state: state(lead.contact_id)},
      %{
        label: "Shoot date",
        detail: Helpers.date_label(lead.desired_date),
        state: state(lead.desired_date)
      },
      %{label: "Venue", detail: lead.location, state: state(lead.location)},
      %{label: "Budget", detail: nil, state: state(lead.budget_cents)},
      %{label: "First reply sent", detail: nil, state: state(lead.first_responded_at)}
    ]
  end

  defp state(nil), do: "todo"
  defp state(_), do: "done"

  defp filter_search(leads, nil), do: leads
  defp filter_search(leads, ""), do: leads

  defp filter_search(leads, term) do
    needle = String.downcase(term)

    Enum.filter(leads, fn lead ->
      String.contains?(String.downcase(lead.name || ""), needle) or
        String.contains?(String.downcase(lead.subtitle || ""), needle) or
        String.contains?(String.downcase(lead.email || ""), needle)
    end)
  end

  defp maybe(opts, _key, nil), do: opts
  defp maybe(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_date(nil), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp to_cents(nil), do: nil
  defp to_cents(amount) when is_float(amount), do: round(amount * 100)
  defp to_cents(amount) when is_integer(amount), do: amount * 100

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &%{field: to_string(field), message: &1})
    end)
  end
end
