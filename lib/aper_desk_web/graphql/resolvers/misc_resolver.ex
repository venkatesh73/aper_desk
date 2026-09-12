defmodule AperDeskWeb.Graphql.Resolvers.MiscResolver do
  @moduledoc """
  Calendar, finance, team, automations and the public pricing table.

  Grouped rather than split into five near-empty modules: each is a single
  screen assembled from contexts that already do the work.
  """

  alias AperDesk.Accounts
  alias AperDesk.Automation
  alias AperDesk.Billing
  alias AperDesk.Billing.Plan
  alias AperDesk.Finance
  alias AperDesk.Formats
  alias AperDesk.Money
  alias AperDesk.People
  alias AperDesk.People.LeaveRequest
  alias AperDesk.Scheduling
  alias AperDeskWeb.Graphql.Resolvers.Helpers

  ## Calendar

  def calendar(_parent, %{month: month, year: year} = args, %{context: %{scope: scope}}) do
    with {:ok, from} <- Date.new(year, month, 1) do
      to = from |> Date.end_of_month() |> Date.add(1)
      period = {DateTime.new!(from, ~T[00:00:00]), DateTime.new!(to, ~T[00:00:00])}
      opts = if args[:shooter_id], do: [user_id: args[:shooter_id]], else: []

      with {:ok, assignments} <- Scheduling.calendar(scope, period, opts) do
        {:ok,
         %{
           days: days(from, assignments),
           clashes: clashes(assignments),
           holds_expiring: holds_expiring(assignments),
           travel: travel(assignments)
         }}
      end
    end
  end

  defp days(from, assignments) do
    last = Date.end_of_month(from).day

    by_day =
      Enum.group_by(assignments, fn assignment ->
        {start, _} = assignment.period
        DateTime.to_date(start).day
      end)

    for day <- 1..last do
      %{
        day: day,
        events:
          by_day
          |> Map.get(day, [])
          |> Enum.map(&%{label: label_for(&1), kind: &1.kind})
      }
    end
  end

  defp label_for(assignment) do
    cond do
      assignment.label -> assignment.label
      assignment.job -> assignment.job.title
      true -> Helpers.humanise(assignment.kind)
    end
  end

  # A clash is two non-hold commitments for the same person that overlap.
  # Computed from the loaded set rather than re-queried, so the calendar shows
  # exactly what it drew.
  defp clashes(assignments) do
    assignments
    |> Enum.reject(&(&1.kind == "hold"))
    |> Enum.group_by(& &1.user_id)
    |> Enum.flat_map(fn {_user_id, list} ->
      for a <- list,
          b <- list,
          a.id < b.id,
          AperDesk.Scheduling.TstzRange.overlaps?(a.period, b.period) do
        {start, _} = a.period

        %{
          id: a.id,
          date: start |> DateTime.to_date() |> Date.to_iso8601(),
          shooter: a.user && a.user.name,
          detail: "#{label_for(a)} overlaps #{label_for(b)}",
          actions: ["reassign", "release", "keep both"]
        }
      end
    end)
  end

  defp holds_expiring(assignments) do
    assignments
    |> Enum.filter(&(&1.kind == "hold" and &1.expires_at))
    |> Enum.map(&%{label: label_for(&1), trailing: Helpers.date_label(&1.expires_at)})
  end

  defp travel(assignments) do
    assignments
    |> Enum.filter(&(&1.kind == "travel"))
    |> Enum.map(&%{label: label_for(&1), detail: nil})
  end

  ## Finance

  def finance(_parent, %{month: month, year: year}, %{context: %{scope: scope}}) do
    with {:ok, invoices} <- Finance.list_invoices(scope, limit: 100),
         {:ok, payouts} <- Finance.list_payouts(scope) do
      outstanding = Helpers.ok_or(Finance.outstanding_total(scope), Money.zero(scope.currency))
      _ = {month, year}

      {:ok,
       %{
         stats: [
           %{
             key: "outstanding",
             value: Money.to_string(outstanding),
             amount_usd: Helpers.to_major(outstanding),
             delta_tone: if(outstanding.amount > 0, do: :warning, else: :positive)
           },
           %{key: "invoices", value: to_string(length(invoices)), delta_tone: :neutral},
           %{
             key: "payouts_pending",
             value: payouts |> Enum.count(&(&1.status == "pending")) |> to_string(),
             delta_tone: :neutral
           }
         ],
         invoices: Enum.map(invoices, &invoice_row/1),
         payouts: Enum.map(payouts, &payout_row/1),
         fx_exposure: fx_exposure(invoices)
       }}
    end
  end

  defp invoice_row(invoice) do
    %{
      id: invoice.id,
      reference: invoice.reference,
      client: invoice.contact && invoice.contact.name,
      due: invoice.due_on && Helpers.date_label(invoice.due_on),
      status: invoice.status,
      status_tone: invoice_tone(invoice),
      amount_usd: Helpers.to_major(invoice.total_cents, invoice.currency)
    }
  end

  defp invoice_tone(invoice) do
    cond do
      invoice.status == "paid" -> :positive
      AperDesk.Finance.Invoice.overdue?(invoice, Date.utc_today()) -> :critical
      invoice.status in ["sent", "partial"] -> :warning
      true -> :neutral
    end
  end

  defp payout_row(payout) do
    %{
      id: payout.id,
      reference: payout.reference,
      person: payout.user && payout.user.name,
      shoot: payout.job && payout.job.title,
      status: payout.status,
      status_tone: if(payout.status == "paid", do: :positive, else: :warning),
      amount_usd: Helpers.to_major(payout.amount_cents, payout.currency)
    }
  end

  # Share of outstanding money held in each currency — the exposure a studio
  # carries if a rate moves before it is paid.
  defp fx_exposure(invoices) do
    outstanding = Enum.reject(invoices, &(&1.status in ["paid", "void", "written_off"]))
    total = Enum.reduce(outstanding, 0, &(&2 + (&1.total_cents - &1.paid_cents)))

    if total == 0 do
      []
    else
      outstanding
      |> Enum.group_by(& &1.currency)
      |> Enum.map(fn {currency, group} ->
        amount = Enum.reduce(group, 0, &(&2 + (&1.total_cents - &1.paid_cents)))
        %{currency: currency, percent: Float.round(amount / total * 100, 1)}
      end)
      |> Enum.sort_by(& &1.percent, :desc)
    end
  end

  ## Team

  def team(_parent, _args, %{context: %{scope: scope}}) do
    with {:ok, members} <- Accounts.list_members(scope) do
      {:ok,
       %{
         staff_count: Enum.count(members, &(&1.employment_type == "staff")),
         freelancer_count: Enum.count(members, &(&1.employment_type == "freelance")),
         members:
           Enum.map(members, fn membership ->
             %{
               id: membership.id,
               name: membership.user && membership.user.name,
               role: membership.role,
               avatar_url: membership.user && membership.user.avatar_url,
               tags: tags_for(membership)
             }
           end),
         leave_requests: leave_requests(scope),
         roster: roster(scope, members),
         contracts: contracts(members),
         onboarding: onboarding(scope)
       }}
    end
  end

  # These three were returning `[]` while the schema promised them, which is a
  # lie the client had no way to detect. They read the same contexts the web UI
  # does, and fall back to empty for a role that may not see them — a
  # photographer asking for the team gets people and no leave queue.
  defp leave_requests(scope) do
    scope
    |> People.list_leave(status: "pending")
    |> Helpers.ok_or([])
    |> Enum.map(fn request ->
      %{
        id: request.id,
        person: (request.user && request.user.name) || "Somebody",
        dates: "#{request.starts_on} – #{request.ends_on}",
        reason: request.reason,
        detail: "#{String.capitalize(request.kind)} · #{LeaveRequest.days(request)} days",
        tone: :warning
      }
    end)
  end

  defp onboarding(scope) do
    scope
    |> People.onboarding_in_progress()
    |> Helpers.ok_or([])
    |> Enum.map(fn row ->
      %{
        person: (row.membership.user && row.membership.user.name) || "Somebody",
        day_label: "#{row.done} of #{row.total} done",
        tasks:
          Enum.map(row.tasks, fn task ->
            %{label: task.label, done: not is_nil(task.done_at)}
          end)
      }
    end)
  end

  # One row per active person, one cell per day of the current week, built from
  # the assignments they are actually on — the same source the web roster uses,
  # so the two cannot disagree.
  defp roster(scope, members) do
    today = Formats.today_for(scope)
    start_day = Formats.week_start_day(scope)
    from = Date.add(today, -rem(Date.day_of_week(today) - start_day + 7, 7))
    days = Enum.map(0..6, &Date.add(from, &1))

    assignments =
      case Scheduling.calendar(
             scope,
             {to_datetime(scope, from), to_datetime(scope, Date.add(from, 7))}
           ) do
        {:ok, list} -> list
        _ -> []
      end

    by_user = Enum.group_by(assignments, & &1.user_id)

    members
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.map(fn membership ->
      %{
        person: (membership.user && membership.user.name) || "Unknown",
        days:
          Enum.map(days, fn day ->
            by_user
            |> Map.get(membership.user_id, [])
            |> Enum.filter(&covers?(&1, day, scope.time_zone))
            |> roster_cell()
          end)
      }
    end)
  end

  defp roster_cell([]), do: %{label: "free", kind: "free"}

  defp roster_cell(assignments) do
    if Enum.any?(assignments, &(&1.kind == "hold" and (&1.label || "") =~ "leave")) do
      %{label: "away", kind: "x"}
    else
      first = hd(assignments)
      %{label: (first.job && first.job.title) || first.label || "Booked", kind: "on"}
    end
  end

  defp covers?(assignment, day, time_zone) do
    {from, to} = assignment.period

    with {:ok, day_start} <- DateTime.new(day, ~T[00:00:00], time_zone),
         {:ok, day_end} <- DateTime.new(Date.add(day, 1), ~T[00:00:00], time_zone) do
      DateTime.compare(from, day_end) == :lt and DateTime.compare(day_start, to) == :lt
    else
      _ -> false
    end
  end

  defp to_datetime(scope, date) do
    case DateTime.new(date, ~T[00:00:00], scope.time_zone) do
      {:ok, datetime} -> datetime
      _ -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  defp tags_for(membership) do
    [%{label: Helpers.humanise(membership.employment_type), tone: :neutral}] ++
      if membership.status == "invited",
        do: [%{label: "Invited", tone: :warning}],
        else: []
  end

  # Freelance contracts that are running out — the thing an HR user needs to
  # see before a shoot is booked against someone whose contract has ended.
  defp contracts(members) do
    today = Date.utc_today()

    members
    |> Enum.filter(& &1.contract_ends_on)
    |> Enum.map(fn membership ->
      days = Date.diff(membership.contract_ends_on, today)

      %{
        person: membership.user && membership.user.name,
        detail: "Contract ends #{Helpers.date_label(membership.contract_ends_on, today)}",
        trailing: "#{days}d",
        tone: if(days <= 30, do: :warning, else: :neutral)
      }
    end)
  end

  ## Automations

  def automations(_parent, _args, %{context: %{scope: scope}}) do
    with {:ok, workflows} <- Automation.list_workflows(scope) do
      {:ok,
       Enum.map(workflows, fn workflow ->
         %{
           id: workflow.id,
           name: workflow.name,
           description: workflow.description,
           mode: workflow.approval_mode,
           enabled: workflow.active
         }
       end)}
    end
  end

  def update_automation(_parent, %{id: id} = args, %{context: %{scope: scope}}) do
    attrs =
      %{}
      |> put_if(args, :mode, "approval_mode")
      |> put_if(args, :enabled, "active")

    case Automation.update_workflow(scope, id, attrs) do
      {:ok, workflow} ->
        {:ok,
         %{
           automation: %{
             id: workflow.id,
             name: workflow.name,
             description: workflow.description,
             mode: workflow.approval_mode,
             enabled: workflow.active
           },
           errors: []
         }}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:ok, %{automation: nil, errors: changeset_errors(changeset)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Plans — public, no scope required

  def plans(_parent, _args, _resolution) do
    {:ok,
     Billing.list_public_plans()
     |> Enum.map(fn plan ->
       %{
         id: plan.id,
         name: plan.name,
         eyebrow: plan.tagline,
         monthly_price_usd: Helpers.to_major(plan.monthly_price_cents, plan.currency),
         for_whom: plan.tagline,
         features: plan.features,
         highlighted: plan.key == "pro"
       }
     end)}
  end

  @doc """
  The comparison table, built from the plans' own limit maps.

  Generated rather than hard-coded, so publishing a new plan version updates
  the pricing page without a deploy — the limits are already data.
  """
  def plan_comparison(_parent, _args, _resolution) do
    plans = Billing.list_public_plans()

    rows =
      for key <- Plan.limit_keys() do
        %{
          label: Helpers.humanise(key),
          solo: limit_label(Enum.at(plans, 0), key),
          studio: limit_label(Enum.at(plans, 1), key),
          agency: limit_label(Enum.at(plans, 2), key)
        }
      end

    {:ok, %{groups: [%{title: "Limits", rows: rows}]}}
  end

  defp limit_label(nil, _key), do: nil

  defp limit_label(plan, key) do
    case Plan.limit(plan, key) do
      :unlimited -> "Unlimited"
      value when key == "storage_bytes" -> "#{Helpers.to_gb(value)} GB"
      value -> to_string(value)
    end
  end

  ## Internals

  defp put_if(attrs, args, key, field) do
    case Map.get(args, key) do
      nil -> attrs
      value -> Map.put(attrs, field, value)
    end
  end

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &%{field: to_string(field), message: &1})
    end)
  end
end
