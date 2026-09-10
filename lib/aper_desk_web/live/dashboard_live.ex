defmodule AperDeskWeb.DashboardLive do
  @moduledoc """
  The signed-in home screen.

  Every number is read from a context rather than assembled here, and which
  numbers appear depends on the role: an owner sees revenue, a photographer
  sees their own week, finance sees what is owed. That filtering happens on the
  server, so a photographer's browser never receives the studio's revenue at
  all — hiding it in the markup would still ship it.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.{Billing, Crm, Finance, Formats, Money, Repo, Scope}
  alias AperDeskWeb.Graphql.Resolvers.Helpers

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(page_title: "Dashboard")
     |> assign(greeting: greeting(scope))
     |> assign(subtitle: subtitle(scope))
     |> assign(stats: stats(scope))
     |> assign(attention: attention(scope))
     |> assign(upcoming: upcoming(scope))
     |> assign(usage: usage(scope))}
  end

  ## Data

  defp greeting(%Scope{user: nil}), do: "Welcome"

  defp greeting(%Scope{user: user} = scope) do
    hour =
      case DateTime.shift_zone(DateTime.utc_now(), scope.time_zone) do
        {:ok, local} -> local.hour
        _ -> DateTime.utc_now().hour
      end

    part =
      cond do
        hour < 12 -> "Good morning"
        hour < 18 -> "Good afternoon"
        true -> "Good evening"
      end

    "#{part}, #{user.name |> String.split(" ") |> List.first()}"
  end

  defp subtitle(scope) do
    overdue = length(Crm.overdue_leads(scope))
    # The studio's own date format and time zone, not the server's.
    today = Formats.date(scope, Formats.today_for(scope))

    case overdue do
      0 -> "#{today} · nothing is overdue"
      1 -> "#{today} · 1 lead is past your reply time"
      n -> "#{today} · #{n} leads are past your reply time"
    end
  end

  defp stats(scope) do
    pipeline = Crm.pipeline_summary(scope)
    open = pipeline |> Map.drop(["completed", "lost"]) |> Map.values() |> Enum.sum()
    overdue = length(Crm.overdue_leads(scope))

    base = [
      %{label: "Open leads", value: to_string(open), detail: nil, tone: :neutral},
      %{
        label: "Booked",
        value: to_string(Map.get(pipeline, "booked", 0)),
        detail: nil,
        tone: :up
      },
      %{
        label: "Awaiting reply",
        value: to_string(overdue),
        detail: if(overdue > 0, do: "past the SLA"),
        tone: if(overdue > 0, do: :down, else: :neutral)
      },
      %{
        label: "Upcoming shoots",
        value: to_string(upcoming_count(scope)),
        detail: nil,
        tone: :neutral
      }
    ]

    # Money is added only for roles permitted to read it — see the module doc.
    if scope.role in [:owner, :finance] do
      outstanding = Finance.outstanding_total(scope)

      base ++
        [
          %{
            label: "Outstanding",
            value: Money.to_string(outstanding),
            detail: if(outstanding.amount > 0, do: "unpaid invoices"),
            tone: if(outstanding.amount > 0, do: :warning, else: :up)
          }
        ]
    else
      base
    end
  end

  defp attention(scope) do
    leads =
      scope
      |> Crm.overdue_leads()
      |> Enum.take(5)
      |> Enum.map(fn lead ->
        %{
          title: (lead.contact && lead.contact.name) || lead.title,
          detail: "No reply yet · #{lead.source}",
          trailing: Helpers.time_ago(lead.first_response_due_at),
          tone: "bad"
        }
      end)

    invoices =
      if scope.role in [:owner, :finance] do
        scope
        |> Finance.overdue_invoices()
        |> Enum.take(3)
        |> Enum.map(fn invoice ->
          %{
            title: invoice.reference,
            detail: "Invoice overdue",
            trailing: Money.to_string(Finance.Invoice.outstanding(invoice)),
            tone: "warn"
          }
        end)
      else
        []
      end

    leads ++ invoices
  end

  defp upcoming(scope) do
    import Ecto.Query

    AperDesk.Scheduling.Job
    |> AperDesk.Scoped.for_studio(scope)
    |> where([j], j.starts_at >= ^DateTime.utc_now() and j.status != "cancelled")
    |> order_by([j], asc: j.starts_at)
    |> limit(5)
    |> Repo.all()
    |> Enum.map(fn job ->
      %{
        id: job.id,
        title: job.title,
        when:
          "#{Formats.relative_date(scope, job.starts_at)} · #{Formats.time(scope, job.starts_at)}",
        where: job.venue_name || job.city
      }
    end)
  end

  defp upcoming_count(scope) do
    import Ecto.Query

    AperDesk.Scheduling.Job
    |> AperDesk.Scoped.for_studio(scope)
    |> where([j], j.starts_at >= ^DateTime.utc_now() and j.status != "cancelled")
    |> select([j], count(j.id))
    |> Repo.one()
  end

  defp usage(scope) do
    case Billing.usage(scope) do
      {:ok, usage} -> usage
      _ -> nil
    end
  end

  @doc "Whether the scope may see a nav entry or panel. Used by the template."
  def can?(scope, permission), do: AperDesk.Authorization.can?(scope, permission)

  @doc "A plan limit key as a reader would say it."
  def meter_label("storage_bytes"), do: "Storage"
  def meter_label("seats"), do: "Users"
  def meter_label(key), do: key |> String.replace("_", " ") |> String.capitalize()

  @doc """
  "3 of 50", with storage in gigabytes.

  Bytes are the right unit to enforce a cap in and the wrong one to show a
  person — "0 of 10737418240" is not a sentence anyone can read.
  """
  def meter_usage(%{key: "storage_bytes", used: used, limit: limit}),
    do: "#{gb(used)} of #{gb(limit)} GB"

  def meter_usage(%{used: used, limit: limit}), do: "#{used} of #{limit}"

  defp gb(bytes) when is_integer(bytes) do
    value = bytes / 1_073_741_824

    # A whole number of gigabytes reads better without the decimal: "0 of 10 GB",
    # not "0.0 of 10 GB".
    if value == Float.round(value), do: round(value), else: Float.round(value, 1)
  end

  defp gb(_), do: 0

  @doc "Renders a 0.0-1.0 utilisation as a percentage, or an em dash when unlimited."
  def percent(nil), do: "—"
  def percent(value) when is_float(value), do: "#{round(value * 100)}%"
  def percent(_), do: "—"
end
