defmodule AperDeskWeb.DashboardLive do
  @moduledoc """
  The signed-in home screen, which is a different screen for each role.

  Not the same panels filtered — a genuinely different question per role,
  because the five people in a studio open this screen wanting five different
  things. The owner wants to know whether the business is winning work. The
  photographer wants to know what they are doing this week. Finance wants to
  know what is owed. HR wants to know who is away and who is half-onboarded.
  Ops wants to know what will go wrong on Saturday.

  Every number is read from a context, so the filtering is the contexts'
  refusals rather than markup this screen hides: a photographer's browser never
  receives the studio's revenue at all, and a photographer's lead counts are
  already narrowed to their own by `AperDesk.Visibility`.

  A context that refuses a read hands back `{:error, :unauthorized}`. This is
  the one screen assembled from many contexts at once, so it treats a refusal
  as "nothing to show here" rather than crashing the mount for everybody.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.{
    Authorization,
    Billing,
    Crm,
    Finance,
    Formats,
    Money,
    Operations,
    People,
    Sales,
    Scheduling,
    Scope
  }

  alias AperDeskWeb.Graphql.Resolvers.Helpers

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(page_title: "Dashboard")
     |> assign(greeting: greeting(scope))
     |> assign(subtitle: subtitle(scope))
     |> assign(role: scope.role || :photographer)
     |> assign(stats: stats(scope))
     |> load_panels(scope)}
  end

  ## Greeting

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

  # The line under the greeting is the one thing most worth saying to this
  # role today, so it differs too.
  defp subtitle(%Scope{role: :hr} = scope) do
    pending = length(ok_or(People.pending_leave(scope), []))
    today = Formats.date(scope, Formats.today_for(scope))

    case pending do
      0 -> "#{today} · no leave to decide"
      1 -> "#{today} · 1 leave request waiting"
      n -> "#{today} · #{n} leave requests waiting"
    end
  end

  defp subtitle(%Scope{role: :ops} = scope) do
    today = Formats.date(scope, Formats.today_for(scope))
    overdue = length(ok_or(Operations.overdue_gear(scope), []))

    case overdue do
      0 -> "#{today} · nothing overdue back"
      n -> "#{today} · #{n} #{if n == 1, do: "piece", else: "pieces"} of kit overdue"
    end
  end

  defp subtitle(%Scope{role: :finance} = scope) do
    today = Formats.date(scope, Formats.today_for(scope))
    overdue = length(ok_or(Finance.overdue_invoices(scope), []))

    case overdue do
      0 -> "#{today} · nothing overdue"
      n -> "#{today} · #{n} #{if n == 1, do: "invoice is", else: "invoices are"} overdue"
    end
  end

  defp subtitle(scope) do
    overdue = length(overdue_leads(scope))
    today = Formats.date(scope, Formats.today_for(scope))

    case overdue do
      0 -> "#{today} · nothing is overdue"
      1 -> "#{today} · 1 lead is past your reply time"
      n -> "#{today} · #{n} leads are past your reply time"
    end
  end

  ## Stats, per role

  defp stats(%Scope{role: :finance} = scope) do
    outstanding = ok_or(Finance.outstanding_total(scope), Money.zero(scope.currency))
    overdue = ok_or(Finance.overdue_invoices(scope), [])
    payouts = ok_or(Finance.list_payouts(scope, status: "pending"), [])

    [
      stat("Outstanding", Money.to_string(outstanding), detail_for_overdue(overdue),
        tone: if(overdue == [], do: :neutral, else: :down)
      ),
      stat("Collected", Money.to_string(collected(scope)), "this month"),
      stat("Awaiting payout", to_string(length(payouts)), "crew, pending approval"),
      stat("Invoices open", to_string(length(open_invoices(scope))), "sent, not settled")
    ]
  end

  defp stats(%Scope{role: :hr} = scope) do
    members = ok_or(AperDesk.Accounts.list_members(scope), [])
    pending = ok_or(People.pending_leave(scope), [])
    onboarding = ok_or(People.onboarding_in_progress(scope), [])
    expiring = expiring_contracts(scope, members)

    [
      stat("The team", to_string(length(members)), staff_split(members)),
      stat("Leave to decide", to_string(length(pending)), nil,
        tone: if(pending == [], do: :neutral, else: :warning)
      ),
      stat("Contracts ending", to_string(length(expiring)), "in the next 30 days",
        tone: if(expiring == [], do: :neutral, else: :warning)
      ),
      stat("Onboarding", to_string(length(onboarding)), "part-way through")
    ]
  end

  defp stats(%Scope{role: :ops} = scope) do
    jobs = upcoming_jobs(scope, 14)
    clashes = ok_or(Scheduling.clashes_in(scope, horizon(scope, 14)), [])
    out = ok_or(Operations.checked_out(scope), [])
    overdue = ok_or(Operations.overdue_gear(scope), [])

    [
      stat("Shoots", to_string(length(jobs)), "next 14 days"),
      stat("Clashes", to_string(length(clashes)), "somebody in two places",
        tone: if(clashes == [], do: :neutral, else: :down)
      ),
      stat("Kit out", to_string(length(out)), overdue_detail(overdue),
        tone: if(overdue == [], do: :neutral, else: :down)
      ),
      stat("Missing an address", to_string(length(missing_venue(jobs))), "before they happen",
        tone: if(missing_venue(jobs) == [], do: :neutral, else: :warning)
      )
    ]
  end

  defp stats(%Scope{role: :photographer} = scope) do
    mine = upcoming_jobs(scope, 7)
    leads = ok_or(Crm.list_leads(scope), [])
    overdue = overdue_leads(scope)
    galleries = ok_or(AperDesk.Galleries.list_galleries(scope), [])

    [
      stat("My shoots", to_string(length(mine)), "this week"),
      stat("My leads", to_string(length(leads)), nil),
      stat("Need a reply", to_string(length(overdue)), "past the studio's target",
        tone: if(overdue == [], do: :neutral, else: :down)
      ),
      stat("My galleries", to_string(length(galleries)), undelivered_detail(galleries))
    ]
  end

  # The owner, and anyone whose role has no dashboard of its own.
  defp stats(scope) do
    pipeline = ok_or(Crm.pipeline_summary(scope), %{})
    open = pipeline |> Map.drop(["completed", "lost"]) |> Map.values() |> Enum.sum()
    overdue = overdue_leads(scope)

    base = [
      stat("Open leads", to_string(open), nil),
      stat("Booked", to_string(Map.get(pipeline, "booked", 0)), nil, tone: :up),
      stat("Awaiting reply", to_string(length(overdue)), if(overdue != [], do: "past the SLA"),
        tone: if(overdue == [], do: :neutral, else: :down)
      )
    ]

    # Quotes out and money owed are the two halves of "is the business
    # working". An owner who can see one and not the other is reading half a
    # sentence, so both are added or neither is.
    base =
      if Authorization.can?(scope, :"quote.read"),
        do:
          base ++ [stat("Quotes out", Money.to_string(open_quote_value(scope)), "no answer yet")],
        else: base

    if Authorization.can?(scope, :"invoice.read") do
      outstanding = ok_or(Finance.outstanding_total(scope), Money.zero(scope.currency))
      overdue_invoices = ok_or(Finance.overdue_invoices(scope), [])

      base ++
        [
          stat("Outstanding", Money.to_string(outstanding), detail_for_overdue(overdue_invoices),
            tone: if(overdue_invoices == [], do: :neutral, else: :warning)
          )
        ]
    else
      base ++
        [stat("Upcoming shoots", to_string(length(upcoming_jobs(scope, 30))), "next 30 days")]
    end
  end

  defp stat(label, value, detail, opts \\ []),
    do: %{label: label, value: value, detail: detail, tone: Keyword.get(opts, :tone, :neutral)}

  ## Panels, per role

  defp load_panels(socket, %Scope{role: :finance} = scope) do
    socket
    |> assign(due_soon: due_soon(scope))
    |> assign(payouts: ok_or(Finance.list_payouts(scope, status: "pending"), []))
    |> assign(usage: nil)
  end

  defp load_panels(socket, %Scope{role: :hr} = scope) do
    socket
    |> assign(leave: ok_or(People.pending_leave(scope), []))
    |> assign(onboarding: ok_or(People.onboarding_in_progress(scope), []))
    |> assign(
      expiring: expiring_contracts(scope, ok_or(AperDesk.Accounts.list_members(scope), []))
    )
    |> assign(usage: nil)
  end

  defp load_panels(socket, %Scope{role: :ops} = scope) do
    jobs = upcoming_jobs(scope, 14)

    socket
    |> assign(jobs: Enum.take(jobs, 8))
    |> assign(clashes: ok_or(Scheduling.clashes_in(scope, horizon(scope, 14)), []))
    # Venue first, notes second: a shoot with no address at all is a worse
    # problem than one with an address and no parking note. Capped, because a
    # dashboard that needs scrolling is a list, not a dashboard.
    |> assign(missing: Enum.take(missing_venue(jobs) ++ missing_notes(jobs), 6))
    |> assign(overdue_gear: ok_or(Operations.overdue_gear(scope), []))
    |> assign(usage: nil)
  end

  defp load_panels(socket, %Scope{role: :photographer} = scope) do
    socket
    |> assign(week: week(scope))
    |> assign(attention: attention(scope))
    |> assign(upcoming: upcoming(scope))
    |> assign(usage: nil)
  end

  defp load_panels(socket, scope) do
    socket
    |> assign(attention: attention(scope))
    |> assign(upcoming: upcoming(scope))
    |> assign(bookings: bookings_by_month(scope))
    |> assign(sources: lead_sources(scope))
    |> assign(usage: usage(scope))
  end

  ## Shared data

  defp attention(scope) do
    leads =
      scope
      |> overdue_leads()
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
      if Authorization.can?(scope, :"invoice.read") do
        scope
        |> Finance.overdue_invoices()
        |> ok_or([])
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
    scope
    |> upcoming_jobs(30)
    |> Enum.take(5)
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

  @doc false
  # The photographer's own week, one column a day, built from the shoots they
  # are actually crewed on — `Visibility` has already narrowed `list_jobs/2`.
  defp week(scope) do
    today = Formats.today_for(scope)
    start_day = Formats.week_start_day(scope)
    offset = rem(Date.day_of_week(today) - start_day + 7, 7)
    from = Date.add(today, -offset)
    days = Enum.map(0..6, &Date.add(from, &1))

    jobs =
      scope
      |> Scheduling.list_jobs(
        from: to_datetime(scope, from),
        to: to_datetime(scope, Date.add(from, 7))
      )
      |> ok_or([])

    for day <- days do
      %{
        date: day,
        today: day == today,
        jobs: Enum.filter(jobs, &(local_date(scope, &1.starts_at) == day))
      }
    end
  end

  defp bookings_by_month(scope) do
    today = Formats.today_for(scope)
    from = Date.beginning_of_month(Date.add(today, -180))

    jobs =
      scope
      |> Scheduling.list_jobs(from: to_datetime(scope, from))
      |> ok_or([])
      |> Enum.reject(&(&1.status == "cancelled"))

    counts =
      Enum.frequencies_by(jobs, fn job ->
        date = local_date(scope, job.starts_at)
        {date.year, date.month}
      end)

    for offset <- -5..2 do
      date = shift_months(Date.beginning_of_month(today), offset)
      key = {date.year, date.month}

      %{
        label: Calendar.strftime(date, "%b"),
        count: Map.get(counts, key, 0),
        past: offset < 0
      }
    end
  end

  defp lead_sources(scope) do
    leads = ok_or(Crm.list_leads(scope, limit: 500), [])

    leads
    |> Enum.frequencies_by(&(&1.source || "unknown"))
    |> Enum.sort_by(&(-elem(&1, 1)))
    |> Enum.take(5)
    |> Enum.map(fn {source, count} ->
      booked =
        Enum.count(leads, &(&1.source == source and &1.stage in ["booked", "completed"]))

      %{
        source: source |> to_string() |> String.replace("_", " ") |> String.capitalize(),
        count: count,
        booked: booked
      }
    end)
  end

  defp due_soon(scope) do
    today = Formats.today_for(scope)

    scope
    |> Finance.list_invoices(outstanding: true)
    |> ok_or([])
    |> Enum.filter(&(&1.due_on && Date.diff(&1.due_on, today) <= 30))
    |> Enum.sort_by(& &1.due_on, Date)
    |> Enum.take(8)
  end

  defp open_invoices(scope) do
    scope |> Finance.list_invoices(outstanding: true) |> ok_or([])
  end

  defp collected(scope) do
    today = Formats.today_for(scope)
    month_start = Date.beginning_of_month(today)

    scope
    |> Finance.list_invoices()
    |> ok_or([])
    |> Enum.filter(&(&1.paid_cents > 0))
    |> Enum.reduce(Money.zero(scope.currency), fn invoice, acc ->
      if invoice.issued_on && Date.compare(invoice.issued_on, month_start) != :lt do
        Money.add(
          acc,
          invoice.paid_cents
          |> Money.new(invoice.currency)
          |> Money.convert(scope.currency, invoice.fx_rate_to_base || Decimal.new(1))
        )
      else
        acc
      end
    end)
  end

  defp open_quote_value(scope) do
    scope
    |> Sales.list_quotes()
    |> ok_or([])
    |> Enum.filter(&(&1.status in Sales.Quote.open_statuses()))
    |> Enum.reduce(Money.zero(scope.currency), fn quote, acc ->
      Money.add(
        acc,
        quote.total_cents
        |> Money.new(quote.currency)
        |> Money.convert(scope.currency, quote.fx_rate_to_base || Decimal.new(1))
      )
    end)
  end

  defp expiring_contracts(scope, members) do
    today = Formats.today_for(scope)

    Enum.filter(members, fn member ->
      member.contract_ends_on && Date.diff(member.contract_ends_on, today) in 0..30
    end)
  end

  defp usage(scope) do
    case Billing.usage(scope) do
      {:ok, usage} -> usage
      _ -> nil
    end
  end

  ## Internals

  defp upcoming_jobs(scope, days) do
    {from, to} = horizon(scope, days)

    scope
    |> Scheduling.list_jobs(from: from, to: to)
    |> ok_or([])
    |> Enum.reject(&(&1.status == "cancelled"))
  end

  defp horizon(scope, days) do
    today = Formats.today_for(scope)
    {to_datetime(scope, today), to_datetime(scope, Date.add(today, days))}
  end

  defp to_datetime(scope, date) do
    case DateTime.new(date, ~T[00:00:00], scope.time_zone) do
      {:ok, datetime} -> datetime
      _ -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  defp local_date(scope, datetime) do
    case DateTime.shift_zone(datetime, scope.time_zone) do
      {:ok, local} -> DateTime.to_date(local)
      _ -> DateTime.to_date(datetime)
    end
  end

  defp shift_months(date, offset) do
    month = date.month - 1 + offset
    year = date.year + Integer.floor_div(month, 12)
    Date.new!(year, rem(rem(month, 12) + 12, 12) + 1, 1)
  end

  defp overdue_leads(scope) do
    case Crm.overdue_leads(scope) do
      {:error, _reason} -> []
      leads -> leads
    end
  end

  defp ok_or({:ok, value}, _fallback), do: value
  defp ok_or({:error, _reason}, fallback), do: fallback
  defp ok_or(value, _fallback), do: value

  defp detail_for_overdue([]), do: "nothing overdue"

  defp detail_for_overdue(overdue),
    do: "#{length(overdue)} overdue"

  defp overdue_detail([]), do: "none overdue"
  defp overdue_detail(overdue), do: "#{length(overdue)} overdue back"

  defp staff_split(members) do
    staff = Enum.count(members, &(&1.employment_type == "staff"))
    freelance = Enum.count(members, &(&1.employment_type == "freelance"))
    "#{staff} staff · #{freelance} freelance"
  end

  defp undelivered_detail(galleries) do
    pending = Enum.count(galleries, &(&1.status in ["draft", "ready"]))
    if pending == 0, do: "all delivered", else: "#{pending} still to deliver"
  end

  def missing_venue(jobs),
    do: Enum.filter(jobs, &(blank?(&1.venue_name) and blank?(&1.venue_address)))

  def missing_notes(jobs),
    do: Enum.filter(jobs, &(not blank?(&1.venue_name) and blank?(&1.venue_notes)))

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  ## Presentation

  def can?(scope, permission), do: Authorization.can?(scope, permission)

  def meter_label("storage_bytes"), do: "Storage"
  def meter_label("seats"), do: "Users"
  def meter_label(key), do: key |> String.replace("_", " ") |> String.capitalize()

  def meter_usage(%{key: "storage_bytes", used: used, limit: limit}),
    do: "#{gb(used)} of #{gb(limit)} GB"

  def meter_usage(%{used: used, limit: limit}), do: "#{used} of #{limit}"

  defp gb(bytes) when is_integer(bytes) do
    value = bytes / 1_073_741_824
    if value == Float.round(value), do: round(value), else: Float.round(value, 1)
  end

  defp gb(_), do: 0

  def percent(nil), do: "—"
  def percent(value) when is_float(value), do: "#{round(value * 100)}%"
  def percent(_), do: "—"

  @doc "The tallest bar in the chart, so the rest can be drawn against it."
  def chart_peak(bookings),
    do: max(Enum.max_by(bookings, & &1.count, fn -> %{count: 0} end).count, 1)

  def day_label(date), do: Calendar.strftime(date, "%a %-d")

  def money(cents, currency), do: cents |> Money.new(currency || "USD") |> Money.to_string()

  def invoice_due(scope, invoice) do
    today = Formats.today_for(scope)

    case Date.diff(invoice.due_on, today) do
      days when days < 0 -> {"bad", "#{abs(days)} days late"}
      0 -> {"warn", "due today"}
      days when days <= 7 -> {"warn", "due in #{days} days"}
      _ -> {"", Formats.date(scope, invoice.due_on)}
    end
  end

  def client_name(%{contact: %{name: name}}), do: name
  def client_name(_invoice), do: "No contact"

  def person(%{user: %{name: name}}), do: name
  def person(%{membership: %{user: %{name: name}}}), do: name
  def person(_row), do: "Unassigned"

  def leave_dates(scope, request),
    do: "#{Formats.date(scope, request.starts_on)} – #{Formats.date(scope, request.ends_on)}"

  def contract_ends(scope, member),
    do: Formats.date(scope, member.contract_ends_on)

  def when_line(scope, job),
    do: "#{Formats.relative_date(scope, job.starts_at)} · #{Formats.time(scope, job.starts_at)}"

  def job_time(scope, job), do: Formats.time(scope, job.starts_at)

  def clash_line(scope, clash), do: Formats.date(scope, clash.starts_at)

  def clash_detail(clash), do: "#{label_of(clash.first)} vs #{label_of(clash.second)}"

  defp label_of(assignment) do
    cond do
      assignment.job -> assignment.job.title
      assignment.label -> assignment.label
      true -> String.capitalize(assignment.kind)
    end
  end

  def venue_problem(job) do
    if blank?(job.venue_name) and blank?(job.venue_address),
      do: "No venue at all",
      else: "#{job.venue_name} · no notes"
  end
end
