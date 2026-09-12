defmodule AperDeskWeb.BookingLive do
  @moduledoc """
  Booking a session, as the client does it.

  The scheduling context could open slots and claim one atomically from the
  first commit, and nothing served a page that let anyone do it — the whole
  feature was reachable only from iex. This is the other half of the consumer
  side: the directory is how a stranger finds a studio, and this is how a
  portrait session gets on the calendar without an email thread.

  Public, so no scope and no account. Only open slots are ever sent to the
  browser; a held or booked one is absent rather than greyed out, because a
  page that renders somebody else's booking has told a stranger when that
  person is being photographed.

  Four steps, and the fourth is deliberately "Confirm" rather than "Deposit":
  the deposit percentage is shown because it is real and the studio set it, but
  nothing here takes a payment, and a button that says "pay" and does not would
  be worse than one that says what it does.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents, only: [empty: 1]

  alias AperDesk.Accounts
  alias AperDesk.Directory
  alias AperDesk.Money
  alias AperDesk.Scheduling
  alias AperDeskWeb.SEO

  @impl true
  def mount(%{"studio" => slug}, _session, socket) do
    case Accounts.get_studio_by_slug(slug) do
      nil ->
        raise AperDeskWeb.NotFoundError, "no studio at #{slug}"

      studio ->
        today = Date.utc_today()

        {:ok,
         socket
         |> assign(:page_layout, false)
         |> assign(studio: studio, month: Date.beginning_of_month(today), today: today)
         |> assign(sessions: Directory.list_public_packages(studio.id))
         |> assign(session: nil, day: nil, slot: nil, booked: nil)
         |> assign(details: %{"name" => "", "email" => "", "phone" => "", "notes" => ""})
         |> assign(error: nil)
         |> load_slots()
         |> assign(SEO.noindex())
         |> assign(page_title: "Book a session with #{studio.name}")}
    end
  end

  ## Choosing

  @impl true
  def handle_event("session", %{"id" => id}, socket) do
    session = Enum.find(socket.assigns.sessions, &(&1.id == id))
    chosen = if socket.assigns.session == session, do: nil, else: session

    {:noreply, socket |> assign(session: chosen, slot: nil) |> load_slots()}
  end

  def handle_event("month", %{"by" => by}, socket) do
    months = String.to_integer(by)
    month = socket.assigns.month |> Date.beginning_of_month() |> shift_month(months)

    # Never back past this month: an empty grid of days that have already
    # happened is not a thing anyone is looking for.
    month =
      if Date.compare(month, Date.beginning_of_month(socket.assigns.today)) == :lt,
        do: Date.beginning_of_month(socket.assigns.today),
        else: month

    {:noreply, socket |> assign(month: month, day: nil, slot: nil) |> load_slots()}
  end

  def handle_event("day", %{"date" => iso}, socket) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> {:noreply, assign(socket, day: date, slot: nil)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("slot", %{"id" => id}, socket) do
    {:noreply, assign(socket, slot: Enum.find(socket.assigns.slots, &(&1.id == id)), error: nil)}
  end

  def handle_event("details", %{"booking" => details}, socket),
    do: {:noreply, assign(socket, details: Map.merge(socket.assigns.details, details))}

  def handle_event("confirm", %{"booking" => details}, socket) do
    slot = socket.assigns.slot
    details = Map.merge(socket.assigns.details, details)

    cond do
      is_nil(slot) ->
        {:noreply, assign(socket, error: "Choose a time first.")}

      blank?(details["name"]) or blank?(details["email"]) ->
        {:noreply, assign(socket, details: details, error: "We need a name and an email.")}

      true ->
        attrs =
          Map.merge(details, %{
            "session_name" => socket.assigns.session && socket.assigns.session.name
          })

        case Scheduling.book_slot(slot.id, attrs) do
          {:ok, %{slot: booked}} ->
            {:noreply, assign(socket, booked: booked, error: nil)}

          {:error, :slot_taken} ->
            # Somebody else got it between this page loading and this click.
            {:noreply,
             socket
             |> assign(slot: nil, error: "Somebody just took that time. Here is what is left.")
             |> load_slots()}

          {:error, _reason} ->
            {:noreply, assign(socket, error: "That did not go through. Try once more.")}
        end
    end
  end

  ## Data

  defp load_slots(socket) do
    month = socket.assigns.month
    from = month |> Date.beginning_of_month() |> to_datetime()
    to = month |> Date.end_of_month() |> Date.add(1) |> to_datetime()

    slots =
      socket.assigns.studio.id
      |> Scheduling.open_slots_for(from, to)
      |> filter_to_session(socket.assigns.session)
      |> Enum.filter(&(DateTime.compare(&1.starts_at, DateTime.utc_now()) == :gt))

    assign(socket,
      slots: slots,
      slots_by_day: Enum.group_by(slots, &DateTime.to_date(&1.starts_at))
    )
  end

  # A slot with no package is open to any session; one tied to a package only
  # shows when that session is chosen.
  defp filter_to_session(slots, nil), do: slots

  defp filter_to_session(slots, session),
    do: Enum.filter(slots, &(is_nil(&1.package_id) or &1.package_id == session.id))

  defp to_datetime(date), do: DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")

  defp shift_month(date, months) do
    total = date.year * 12 + (date.month - 1) + months
    Date.new!(div(total, 12), rem(total, 12) + 1, 1)
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  ## Presentation

  @doc "The weeks of `month`, Monday first, padded with the days either side."
  def weeks(month) do
    first = Date.beginning_of_month(month)
    last = Date.end_of_month(month)

    start = Date.add(first, -(Date.day_of_week(first) - 1))
    finish = Date.add(last, 7 - Date.day_of_week(last))

    Date.range(start, finish) |> Enum.chunk_every(7)
  end

  def step_state(step, %{session: nil}), do: if(step == 1, do: "on", else: "")
  def step_state(1, _assigns), do: "done"
  def step_state(step, %{slot: nil}), do: if(step == 2, do: "on", else: "")
  def step_state(2, _assigns), do: "done"
  def step_state(3, %{booked: nil}), do: "on"
  def step_state(3, _assigns), do: "done"
  def step_state(4, %{booked: nil}), do: ""
  def step_state(4, _assigns), do: "on"

  def session_price(%{price_cents: 0}), do: "Free"

  def session_price(session),
    do: Money.to_string(Money.new(session.price_cents, session.price_currency || "USD"))

  def session_length(%{duration_minutes: nil}), do: nil
  def session_length(%{duration_minutes: m}) when m < 60, do: "#{m} min"
  def session_length(%{duration_minutes: m}) when rem(m, 60) == 0, do: "#{div(m, 60)} h"
  def session_length(%{duration_minutes: m}), do: "#{Float.round(m / 60, 1)} h"

  def deposit_amount(nil), do: nil
  def deposit_amount(%{deposit_percent: nil}), do: nil
  def deposit_amount(%{deposit_percent: 0}), do: nil

  def deposit_amount(session) do
    cents = div(session.price_cents * session.deposit_percent, 100)
    Money.to_string(Money.new(cents, session.price_currency || "USD"))
  end

  def clock(%DateTime{} = at, zone) do
    at |> DateTime.shift_zone!(zone) |> Calendar.strftime("%H:%M")
  rescue
    _error -> Calendar.strftime(at, "%H:%M")
  end

  def slot_length(slot) do
    minutes = DateTime.diff(slot.ends_at, slot.starts_at, :minute)
    if minutes < 60, do: "#{minutes} min", else: "#{Float.round(minutes / 60, 1)} h"
  end
end
