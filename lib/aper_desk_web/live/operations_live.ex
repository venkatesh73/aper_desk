defmodule AperDeskWeb.OperationsLive do
  @moduledoc """
  Whether the next few days can actually happen.

  That is a different question from what the calendar answers. A shoot with two
  bodies booked and one of them at the repair shop is in the calendar and is
  not going to work; a Saturday with no venue notes is in the calendar and will
  cost somebody an hour on the phone on Friday night.

  So this screen leads with what is *missing* rather than with what is booked:
  kit that has not come back, dates with two people expected in two places, and
  shoots nobody has written down how to get to.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Formats
  alias AperDesk.Operations
  alias AperDesk.People
  alias AperDesk.Scheduling

  @horizon_days 14

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Operations")
     |> assign(tab: "today")
     |> load()}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(today gear) do
    {:noreply, socket |> assign(tab: tab) |> load()}
  end

  def handle_event("check-out", %{"checkout" => params}, socket) do
    attrs =
      params
      |> Map.take(["user_id", "job_id", "due_back_on"])
      |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

    case Operations.check_out(socket.assigns.current_scope, params["gear_item_id"], attrs) do
      {:ok, _checkout} ->
        {:noreply, socket |> load() |> put_flash(:info, "Signed out.")}

      {:error, :already_out} ->
        {:noreply,
         put_flash(socket, :error, "Somebody already has that. Check it back in first.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not sign it out: #{inspect(reason)}")}
    end
  end

  def handle_event("check-in", %{"id" => id}, socket) do
    case Operations.check_in(socket.assigns.current_scope, id) do
      {:ok, _checkout} ->
        {:noreply, socket |> load() |> put_flash(:info, "Back in.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not check it in: #{inspect(reason)}")}
    end
  end

  def handle_event("add-gear", %{"gear" => params}, socket) do
    case Operations.create_gear(socket.assigns.current_scope, params) do
      {:ok, item} ->
        {:noreply, socket |> load() |> put_flash(:info, "#{item.name} added.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "That needs a name at least.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not add it: #{inspect(reason)}")}
    end
  end

  def handle_event("retire-gear", %{"id" => id}, socket) do
    case Operations.retire_gear(socket.assigns.current_scope, id) do
      {:ok, item} ->
        {:noreply, socket |> load() |> put_flash(:info, "#{item.name} retired.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not retire it: #{inspect(reason)}")}
    end
  end

  ## Data

  defp load(socket) do
    scope = socket.assigns.current_scope
    today = Formats.today_for(scope)
    window = window(scope, today)

    assignments = ok_or(Scheduling.calendar(scope, window), [])

    socket
    |> assign(today: today)
    |> assign(jobs: upcoming_jobs(scope, today))
    |> assign(clashes: ok_or(Scheduling.clashes_in(scope, window), []))
    |> assign(travel: Enum.filter(assignments, &(&1.kind == "travel")))
    |> assign(away: ok_or(People.leave_between(scope, today, Date.add(today, @horizon_days)), []))
    |> assign(out: ok_or(Operations.checked_out(scope), []))
    |> assign(overdue: ok_or(Operations.overdue_gear(scope, today), []))
    |> assign(gear: ok_or(Operations.list_gear(scope), []))
    |> assign(available: ok_or(Operations.available_gear(scope), []))
    |> assign(members: members(scope))
  end

  defp window(scope, today) do
    {:ok, from} = DateTime.new(today, ~T[00:00:00], scope.time_zone)
    {:ok, to} = DateTime.new(Date.add(today, @horizon_days), ~T[00:00:00], scope.time_zone)
    {from, to}
  end

  defp upcoming_jobs(scope, today) do
    {from, to} = window(scope, today)

    scope
    |> Scheduling.list_jobs(from: from, to: to)
    |> ok_or([])
    |> Enum.reject(&(&1.status == "cancelled"))
  end

  defp members(scope) do
    case AperDesk.Accounts.list_members(scope) do
      {:ok, members} -> Enum.filter(members, &(&1.status == "active"))
      _ -> []
    end
  end

  defp ok_or({:ok, value}, _fallback), do: value
  defp ok_or({:error, _reason}, fallback), do: fallback
  defp ok_or(value, _fallback) when is_list(value), do: value
  defp ok_or(_other, fallback), do: fallback

  ## Presentation

  def horizon_days, do: @horizon_days

  @doc """
  Shoots with nowhere written down.

  The single most common Friday-night phone call, and the one thing on this
  screen that is cheap to fix in advance.
  """
  def missing_venue(jobs),
    do: Enum.filter(jobs, &(blank?(&1.venue_name) and blank?(&1.venue_address)))

  def missing_notes(jobs),
    do: Enum.filter(jobs, &(not blank?(&1.venue_name) and blank?(&1.venue_notes)))

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  def when_line(scope, job),
    do: "#{Formats.relative_date(scope, job.starts_at)} · #{Formats.time(scope, job.starts_at)}"

  def where_line(job), do: job.venue_name || job.city || "Nowhere written down"

  def person(%{user: %{name: name}}), do: name
  def person(_row), do: "Unassigned"

  def gear_categories,
    do: Enum.map(AperDesk.Operations.GearItem.categories(), &{String.capitalize(&1), &1})

  def due_line(_scope, %{due_back_on: nil}), do: "No date promised"

  def due_line(scope, %{due_back_on: due} = checkout) do
    today = Formats.today_for(scope)

    cond do
      AperDesk.Operations.GearCheckout.overdue?(checkout, today) ->
        "#{Date.diff(today, due)} days overdue"

      Date.compare(due, today) == :eq ->
        "Back today"

      true ->
        "Back #{Formats.date(scope, due)}"
    end
  end

  def overdue?(scope, checkout),
    do: AperDesk.Operations.GearCheckout.overdue?(checkout, Formats.today_for(scope))

  def member_options(members),
    do: Enum.map(members, &{(&1.user && &1.user.name) || "Unknown", &1.user_id})

  def job_options(jobs), do: Enum.map(jobs, &{&1.title, &1.id})

  def away_line(scope, request),
    do: "#{Formats.date(scope, request.starts_on)} – #{Formats.date(scope, request.ends_on)}"

  def clash_line(scope, clash), do: Formats.date(scope, clash.starts_at)

  def clash_detail(clash) do
    "#{label_of(clash.first)} vs #{label_of(clash.second)}"
  end

  defp label_of(assignment) do
    cond do
      assignment.job -> assignment.job.title
      assignment.label -> assignment.label
      true -> String.capitalize(assignment.kind)
    end
  end
end
