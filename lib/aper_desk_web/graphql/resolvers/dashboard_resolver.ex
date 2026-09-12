defmodule AperDeskWeb.Graphql.Resolvers.DashboardResolver do
  @moduledoc """
  The home screen, assembled per role.

  Each role sees the numbers it can act on: an owner sees revenue, a
  photographer sees their own shoots, finance sees what is owed. Filtering here
  rather than in the client means a photographer's device never receives the
  studio's revenue figures at all.
  """

  import Ecto.Query

  alias AperDesk.Crm
  alias AperDesk.Finance
  alias AperDesk.Money
  alias AperDesk.Repo
  alias AperDesk.Scheduling.Job
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias AperDeskWeb.Graphql.Resolvers.Helpers

  def dashboard(_parent, args, %{context: %{scope: scope}}) do
    role = args[:role] || to_string(scope.role)
    now = DateTime.utc_now()

    {:ok,
     %{
       greeting: greeting(scope, now),
       subtitle: subtitle(scope, role),
       stats: stats(scope, role),
       bookings_by_month: bookings_by_month(scope),
       needs_attention: needs_attention(scope),
       upcoming_shoots: upcoming_shoots(scope, now),
       leads_by_source: leads_by_source(scope)
     }}
  end

  defp greeting(%Scope{user: nil}, _now), do: "Welcome"

  defp greeting(%Scope{user: user} = scope, now) do
    hour =
      case DateTime.shift_zone(now, scope.time_zone) do
        {:ok, local} -> local.hour
        _ -> now.hour
      end

    part =
      cond do
        hour < 12 -> "Good morning"
        hour < 18 -> "Good afternoon"
        true -> "Good evening"
      end

    "#{part}, #{user.name |> String.split(" ") |> List.first()}"
  end

  defp subtitle(scope, role) do
    overdue = length(Helpers.ok_or(Crm.overdue_leads(scope), []))

    case {role, overdue} do
      {_, 0} -> "Nothing is overdue. Nice."
      {_, 1} -> "1 enquiry is past your reply time."
      {_, n} -> "#{n} enquiries are past your reply time."
    end
  end

  # Money stats are omitted for roles that may not read them, rather than
  # zeroed — a zero would read as "no revenue", which is a different claim.
  defp stats(scope, role) do
    pipeline = Helpers.ok_or(Crm.pipeline_summary(scope), %{})
    open = pipeline |> Map.drop(["completed", "lost"]) |> Map.values() |> Enum.sum()

    base = [
      %{key: "open_leads", value: to_string(open), delta: nil, delta_tone: :neutral},
      %{
        key: "booked",
        value: to_string(Map.get(pipeline, "booked", 0)),
        delta: nil,
        delta_tone: :positive
      },
      %{
        key: "upcoming_shoots",
        value: to_string(count_upcoming(scope)),
        delta: nil,
        delta_tone: :neutral
      }
    ]

    if role in ["owner", "finance"] do
      outstanding = Helpers.ok_or(Finance.outstanding_total(scope), Money.zero(scope.currency))

      base ++
        [
          %{
            key: "outstanding",
            value: Money.to_string(outstanding),
            amount_usd: Helpers.to_major(outstanding),
            delta: nil,
            delta_tone: if(outstanding.amount > 0, do: :warning, else: :positive)
          }
        ]
    else
      base
    end
  end

  defp bookings_by_month(scope) do
    today = Date.utc_today()
    from_date = today |> Date.add(-150) |> Date.beginning_of_month()

    counts =
      Job
      |> Scoped.for_studio(scope)
      |> where([j], j.starts_at >= ^DateTime.new!(from_date, ~T[00:00:00]))
      |> group_by([j], fragment("date_trunc('month', ?)", j.starts_at))
      |> select([j], {fragment("date_trunc('month', ?)", j.starts_at), count(j.id)})
      |> Repo.all()
      |> Map.new(fn {month, count} ->
        {DateTime.to_date(month) |> Date.beginning_of_month(), count}
      end)

    for offset <- -5..0 do
      month = today |> Date.add(offset * 30) |> Date.beginning_of_month()

      %{
        month: Calendar.strftime(month, "%b"),
        count: Map.get(counts, month, 0),
        past: offset < 0
      }
    end
  end

  defp needs_attention(scope) do
    overdue = Helpers.ok_or(Crm.overdue_leads(scope), [])

    invoices =
      if Scope.tenant?(scope),
        do: Helpers.ok_or(Finance.overdue_invoices(scope), []),
        else: []

    Enum.map(overdue, fn lead ->
      %{
        title: (lead.contact && lead.contact.name) || lead.title,
        subtitle: "No reply yet",
        trailing: Helpers.time_ago(lead.first_response_due_at),
        tone: :critical
      }
    end) ++
      Enum.map(invoices, fn invoice ->
        %{
          title: invoice.reference,
          subtitle: "Invoice overdue",
          trailing: Money.to_string(AperDesk.Finance.Invoice.outstanding(invoice)),
          tone: :warning
        }
      end)
  end

  defp upcoming_shoots(scope, now) do
    Job
    |> Scoped.for_studio(scope)
    |> where([j], j.starts_at >= ^now and j.status not in ^["cancelled"])
    |> order_by([j], asc: j.starts_at)
    |> limit(5)
    |> Repo.all()
    |> Enum.map(fn job ->
      %{
        id: job.id,
        title: job.title,
        when: Helpers.date_label(job.starts_at),
        where: job.venue_name || job.city,
        image_url: nil
      }
    end)
  end

  defp leads_by_source(scope) do
    AperDesk.Crm.Lead
    |> Scoped.for_studio(scope)
    |> group_by([l], l.source)
    |> select(
      [l],
      {l.source, count(l.id), sum(fragment("CASE WHEN ? = 'booked' THEN 1 ELSE 0 END", l.stage))}
    )
    |> Repo.all()
    |> Enum.map(fn {source, count, booked} ->
      booked = to_int(booked)

      %{
        source: source || "unknown",
        count: count,
        booked_rate: if(count > 0, do: booked / count, else: 0.0)
      }
    end)
  end

  defp count_upcoming(scope) do
    now = DateTime.utc_now()

    Job
    |> Scoped.for_studio(scope)
    |> where([j], j.starts_at >= ^now and j.status not in ^["cancelled"])
    |> select([j], count(j.id))
    |> Repo.one()
  end

  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
end
