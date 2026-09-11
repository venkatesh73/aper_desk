defmodule AperDeskWeb.CalendarLive do
  @moduledoc """
  The month view, and the form that books a shoot into it.

  Weeks start on the day the studio chose during setup, so a studio that thinks
  in Sunday-first weeks is not handed a Monday-first grid.

  Clashes are computed from the same set of assignments the grid draws, through
  `Scheduling.clashes_in/3` — so the panel can never disagree with the squares
  above it. Every one of them involves a hold, because the exclusion constraint
  refuses to write any other kind of overlap; the panel exists for the overlaps
  the database was deliberately told to allow.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Accounts
  alias AperDesk.Formats
  alias AperDesk.Scheduling
  alias AperDesk.Scheduling.{Assignment, Job}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, shooter_id: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    scope = socket.assigns.current_scope
    today = Formats.today_for(scope)

    month =
      case {params["year"], params["month"]} do
        {year, month} when is_binary(year) and is_binary(month) ->
          with {y, ""} <- Integer.parse(year),
               {m, ""} <- Integer.parse(month),
               {:ok, date} <- Date.new(y, m, 1) do
            date
          else
            _ -> Date.beginning_of_month(today)
          end

        _ ->
          Date.beginning_of_month(today)
      end

    socket
    |> assign(page_title: "Calendar")
    |> assign(month: month, today: today)
    |> assign(members: members(scope))
    |> load_month()
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns.current_scope

    socket
    |> assign(page_title: "New shoot")
    |> assign(members: members(scope))
    |> assign(contacts: contacts(scope))
    |> assign(crew_id: nil, clash: nil)
    |> assign(form: to_form(Job.changeset(%Job{}, %{}), as: :job))
  end

  @impl true
  def handle_event("shooter", %{"id" => id}, socket) do
    shooter = if id == "", do: nil, else: id
    {:noreply, socket |> assign(shooter_id: shooter) |> load_month()}
  end

  def handle_event("release-hold", %{"id" => id}, socket) do
    case Scheduling.release(socket.assigns.current_scope, id) do
      {:ok, _assignment} ->
        {:noreply, socket |> put_flash(:info, "Hold released.") |> load_month()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not release it: #{inspect(reason)}")}
    end
  end

  def handle_event("validate", %{"job" => params}, socket) do
    # Validated on the anchored params, so the changeset holds a real instant
    # rather than a wall clock read as UTC — `validate_end_after_start` and
    # every later read then agree with what is stored. `datetime_input/2` puts
    # it back on the studio's clock for the field.
    changeset =
      %Job{}
      |> Job.changeset(localise(params, socket.assigns.current_scope))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(form: to_form(changeset, as: :job))
     |> assign(crew_id: params["crew_id"] || socket.assigns.crew_id)
     |> check_clash(params)}
  end

  def handle_event("save", %{"job" => params}, socket) do
    scope = socket.assigns.current_scope
    crew_id = params["crew_id"] || socket.assigns.crew_id
    crew = if crew_id in [nil, ""], do: [], else: [%{user_id: crew_id}]

    attrs = params |> Map.drop(["crew_id"]) |> localise(scope)

    case Scheduling.create_job(scope, attrs, crew) do
      {:ok, job} ->
        month = local_date(job.starts_at, scope)

        {:noreply,
         socket
         |> put_flash(:info, "#{job.title} booked.")
         |> push_navigate(to: ~p"/app/calendar?year=#{month.year}&month=#{month.month}")}

      {:error, {:clash, conflicting}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That person is already committed: #{describe_clash(conflicting)}. Pick someone else or change the time."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :job))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not book it: #{inspect(reason)}")}
    end
  end

  # The browser sends wall-clock time with no zone. Read as UTC it would land
  # hours away from the time the studio typed, so it is anchored to the
  # studio's own zone here, and the zone is recorded alongside it.
  defp localise(params, scope) do
    params
    |> put_utc("starts_at", scope)
    |> put_utc("ends_at", scope)
    |> Map.put("time_zone", scope.time_zone)
  end

  defp put_utc(params, key, scope) do
    case parse_time(params[key], scope) do
      {:ok, datetime} -> Map.put(params, key, DateTime.to_iso8601(datetime))
      _ -> params
    end
  end

  ## Data

  defp load_month(socket) do
    scope = socket.assigns.current_scope
    month = socket.assigns.month
    {from, to} = month_window(scope, month)
    opts = if socket.assigns.shooter_id, do: [user_id: socket.assigns.shooter_id], else: []

    assignments =
      case Scheduling.calendar(scope, {from, to}, opts) do
        {:ok, list} -> list
        _ -> []
      end

    clashes =
      case Scheduling.clashes_in(scope, {from, to}, opts) do
        {:ok, pairs} -> pairs
        _ -> []
      end

    jobs = jobs_in(scope, {from, to}, assignments, socket.assigns.shooter_id)

    socket
    |> assign(assignments: assignments)
    |> assign(clashes: clashes)
    |> assign(holds: Scheduling.holds_expiring(scope))
    |> assign(travel: Enum.filter(assignments, &(&1.kind == "travel")))
    |> assign(cells: build_cells(scope, month, jobs, assignments, clashes))
  end

  # A shoot belongs on the grid whether or not anyone is assigned to it yet —
  # drawing only assignments would hide exactly the jobs that still need crew.
  # Filtering by shooter is the one case where that flips: then the question is
  # "what is this person doing", so only jobs they are actually on count.
  defp jobs_in(scope, {from, to}, assignments, shooter_id) do
    jobs =
      case Scheduling.list_jobs(scope, from: from, to: to) do
        {:ok, list} -> Enum.reject(list, &(&1.status == "cancelled"))
        _ -> []
      end

    if shooter_id do
      theirs = assignments |> Enum.map(& &1.job_id) |> MapSet.new()
      Enum.filter(jobs, &MapSet.member?(theirs, &1.id))
    else
      jobs
    end
  end

  # The grid covers whole weeks, so it starts on the studio's chosen first day
  # before the 1st and ends after the last — the greyed cells either side.
  defp month_window(scope, month) do
    start_day = Formats.week_start_day(scope)
    first = Date.beginning_of_month(month)
    last = Date.end_of_month(month)

    grid_start = Date.add(first, -offset(first, start_day))
    grid_end = Date.add(last, 6 - offset_from_end(last, start_day))

    {DateTime.new!(grid_start, ~T[00:00:00]), DateTime.new!(Date.add(grid_end, 1), ~T[00:00:00])}
  end

  defp offset(date, start_day), do: rem(Date.day_of_week(date) - start_day + 7, 7)
  defp offset_from_end(date, start_day), do: rem(Date.day_of_week(date) - start_day + 7, 7)

  defp build_cells(scope, month, jobs, assignments, clashes) do
    {from, _to} = month_window(scope, month)
    grid_start = DateTime.to_date(from)
    today = Formats.today_for(scope)

    clashing_jobs =
      clashes
      |> Enum.flat_map(&[&1.first, &1.second])
      |> Enum.map(& &1.job_id)
      |> MapSet.new()

    clashing_assignments =
      clashes |> Enum.flat_map(&[&1.first.id, &1.second.id]) |> MapSet.new()

    events =
      Enum.map(jobs, fn job ->
        {local_date(job.starts_at, scope),
         %{label: job.title, kind: job_kind(job, clashing_jobs)}}
      end) ++
        (assignments
         |> Enum.filter(&is_nil(&1.job_id))
         |> Enum.map(fn assignment ->
           {starts_at, _ends} = assignment.period

           {local_date(starts_at, scope),
            %{
              label: event_label(assignment),
              kind: assignment_kind(assignment, clashing_assignments)
            }}
         end))

    by_day = Enum.group_by(events, &elem(&1, 0), &elem(&1, 1))

    for offset <- 0..41 do
      date = Date.add(grid_start, offset)

      %{
        date: date,
        in_month: date.month == month.month,
        today: date == today,
        events: Map.get(by_day, date, [])
      }
    end
    |> Enum.chunk_every(7)
    |> Enum.reject(fn week -> Enum.all?(week, &(not &1.in_month)) end)
    |> List.flatten()
  end

  defp local_date(%DateTime{} = datetime, scope) do
    case DateTime.shift_zone(datetime, scope.time_zone) do
      {:ok, local} -> DateTime.to_date(local)
      _ -> DateTime.to_date(datetime)
    end
  end

  defp job_kind(job, clashing_jobs) do
    cond do
      MapSet.member?(clashing_jobs, job.id) -> "clash"
      job.status == "hold" -> "hold"
      true -> ""
    end
  end

  defp assignment_kind(%Assignment{} = assignment, clashing_ids) do
    cond do
      MapSet.member?(clashing_ids, assignment.id) -> "clash"
      assignment.kind == "hold" -> "hold"
      assignment.kind == "travel" -> "travel"
      true -> ""
    end
  end

  defp event_label(%Assignment{} = assignment) do
    cond do
      assignment.job -> assignment.job.title
      assignment.label -> assignment.label
      true -> String.capitalize(assignment.kind)
    end
  end

  defp members(scope) do
    case Accounts.list_members(scope) do
      {:ok, members} -> Enum.filter(members, &(&1.status == "active"))
      _ -> []
    end
  end

  defp contacts(scope) do
    case AperDesk.Crm.list_contacts(scope, limit: 200) do
      {:ok, contacts} -> contacts
      _ -> []
    end
  end

  # Warns before saving rather than after. The database is still the authority —
  # `create_job/3` returns the clash — but a warning while the form is open is
  # cheaper than a rejected submit.
  defp check_clash(socket, params) do
    scope = socket.assigns.current_scope
    crew_id = params["crew_id"] || socket.assigns.crew_id

    with false <- crew_id in [nil, ""],
         {:ok, starts_at} <- parse_time(params["starts_at"], scope),
         {:ok, ends_at} <- parse_time(params["ends_at"], scope),
         true <- DateTime.compare(ends_at, starts_at) == :gt do
      case Scheduling.clashes_for(scope, crew_id, {starts_at, ends_at}, blocking_only: true) do
        [] -> assign(socket, clash: nil)
        conflicting -> assign(socket, clash: describe_clash(conflicting))
      end
    else
      _ -> assign(socket, clash: nil)
    end
  end

  defp parse_time(nil, _scope), do: :error
  defp parse_time("", _scope), do: :error

  defp parse_time(value, scope) do
    case NaiveDateTime.from_iso8601(value <> ":00") do
      {:ok, naive} -> DateTime.from_naive(naive, scope.time_zone)
      _ -> :error
    end
  end

  defp describe_clash(assignments) do
    assignments
    |> Enum.map(fn assignment -> event_label(assignment) end)
    |> Enum.join(", ")
  end

  ## Presentation

  def month_label(month), do: Calendar.strftime(month, "%B %Y")

  def prev_month(month), do: month |> Date.add(-1) |> Date.beginning_of_month()

  def next_month(month), do: month |> Date.end_of_month() |> Date.add(1)

  @doc "Weekday headings, rotated to the studio's chosen first day."
  def weekday_names(scope) do
    names = ~w(Mon Tue Wed Thu Fri Sat Sun)
    start = Formats.week_start_day(scope)
    Enum.slice(names, (start - 1)..6) ++ Enum.slice(names, 0, start - 1)
  end

  def clash_when(scope, clash), do: Formats.date(scope, clash.starts_at)

  def hold_expires(scope, hold), do: Formats.relative_date(scope, hold.expires_at)

  def hold_label(hold), do: (hold.job && hold.job.title) || hold.label || "Hold"

  @doc "A label for one assignment, used by the clash and travel panels."
  def event_label_for(assignment) do
    cond do
      assignment.job -> assignment.job.title
      assignment.label -> assignment.label
      true -> String.capitalize(assignment.kind)
    end
  end

  def member_options(members),
    do: Enum.map(members, &{(&1.user && &1.user.name) || "Unknown", &1.user_id})

  @doc """
  What a `datetime-local` input will actually accept: `2026-11-14T10:00`.

  The changeset renders its *cast* value, so once a time has been cast the
  input would be handed a UTC ISO-8601 string — which the browser rejects by
  silently emptying the field as you type into it. This narrows whatever is
  there back to the studio's own wall clock.
  """
  def datetime_input(scope, value)

  def datetime_input(scope, %DateTime{} = value) do
    case DateTime.shift_zone(value, scope.time_zone) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%dT%H:%M")
      _ -> Calendar.strftime(value, "%Y-%m-%dT%H:%M")
    end
  end

  def datetime_input(_scope, value) when is_binary(value), do: String.slice(value, 0, 16)
  def datetime_input(_scope, _value), do: nil

  def shoot_types, do: AperDesk.Crm.Lead.shoot_types()

  def humanise(value), do: value |> String.replace("_", " ") |> String.capitalize()
end
