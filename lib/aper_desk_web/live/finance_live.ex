defmodule AperDeskWeb.FinanceLive do
  @moduledoc """
  The money in one screen: what is owed in, and what is owed out.

  Two ledgers side by side because they are the same question from opposite
  ends — a studio with £31,000 outstanding and £4,350 of crew to pay on Friday
  is in a different position from one with the same total and nothing due, and
  a page that showed only invoices would not say so.

  Every total here is summed per currency and converted with each row's own
  stored rate. Summing after conversion is the bug this shape exists to avoid:
  an invoice issued in March must keep converting at March's rate, or last
  quarter's revenue restates itself every time the rate table refreshes.

  Payouts are approved as a run rather than one at a time. `Finance.approve_payouts/2`
  refuses a partial run, so the checkbox selection is all-or-nothing by design
  — crew silently left out of a Friday payment is the failure that matters.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Finance
  alias AperDesk.Finance.Invoice
  alias AperDesk.Formats
  alias AperDesk.Money

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Finance")
     |> assign(status: nil, selected: MapSet.new())
     |> load()}
  end

  @impl true
  def handle_event("status", %{"status" => status}, socket) do
    status = if status == "", do: nil, else: status
    {:noreply, socket |> assign(status: status) |> load()}
  end

  def handle_event("toggle-payout", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("select-all-payouts", _params, socket) do
    pending =
      socket.assigns.payouts |> Enum.filter(&(&1.status == "pending")) |> Enum.map(& &1.id)

    selected =
      if MapSet.size(socket.assigns.selected) == length(pending),
        do: MapSet.new(),
        else: MapSet.new(pending)

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("approve-run", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    case Finance.approve_payouts(socket.assigns.current_scope, ids) do
      {:ok, %{payouts: payouts}} ->
        {:noreply,
         socket
         |> assign(selected: MapSet.new())
         |> load()
         |> put_flash(:info, "#{length(payouts)} approved as one run.")}

      {:error, {:not_all_pending, approved, asked}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Nothing was approved: #{asked - approved} of those are no longer pending. Reload and try again."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not approve the run: #{inspect(reason)}")}
    end
  end

  ## Data

  defp load(socket) do
    scope = socket.assigns.current_scope
    today = Formats.today_for(scope)

    opts = if socket.assigns.status, do: [status: socket.assigns.status], else: []

    invoices =
      case Finance.list_invoices(scope, opts) do
        {:ok, list} -> list
        _ -> []
      end

    payouts =
      case Finance.list_payouts(scope) do
        {:ok, list} -> Enum.sort_by(list, &{payout_order(&1.status), &1.inserted_at})
        _ -> []
      end

    overdue =
      case Finance.overdue_invoices(scope, today) do
        {:ok, list} -> list
        list when is_list(list) -> list
        _ -> []
      end

    socket
    |> assign(today: today)
    |> assign(invoices: invoices, payouts: payouts, overdue: overdue)
    |> assign(outstanding: Finance.outstanding_total(scope))
    |> assign(overdue_total: total_of(scope, overdue, &outstanding_cents/1))
    |> assign(payouts_due: payouts_due(scope, payouts))
    |> assign(collected: collected(scope, invoices))
    |> assign(exposure: exposure(scope, invoices))
  end

  defp payout_order("pending"), do: 0
  defp payout_order("approved"), do: 1
  defp payout_order("paid"), do: 2
  defp payout_order(_other), do: 3

  defp outstanding_cents(%Invoice{} = invoice),
    do: max(invoice.total_cents - invoice.paid_cents, 0)

  # Converted row by row with each row's stored rate, then added. Converting
  # the sum instead would apply one rate to a mixed-currency pile.
  defp total_of(scope, rows, amount_fun) do
    Enum.reduce(rows, Money.zero(scope.currency), fn row, acc ->
      converted =
        row
        |> amount_fun.()
        |> Money.new(row.currency)
        |> Money.convert(scope.currency, Map.get(row, :fx_rate_to_base) || Decimal.new(1))

      Money.add(acc, converted)
    end)
  end

  defp payouts_due(scope, payouts) do
    payouts
    |> Enum.filter(&(&1.status in ~w(pending approved)))
    |> Enum.reduce(Money.zero(scope.currency), fn payout, acc ->
      # A payout carries no rate of its own, so it is taken at par when it is
      # already in the studio's currency and left out of the headline when it
      # is not — a made-up rate would be worse than an honest omission.
      if payout.currency == scope.currency do
        Money.add(acc, Money.new(payout.amount_cents, payout.currency))
      else
        acc
      end
    end)
  end

  defp collected(scope, invoices),
    do: total_of(scope, invoices, & &1.paid_cents)

  # Which currencies the outstanding money is actually in. A studio billing in
  # three currencies carries a risk that a single base-currency total hides.
  defp exposure(scope, invoices) do
    outstanding = Enum.filter(invoices, &(&1.status in Invoice.outstanding_statuses()))

    totals =
      outstanding
      |> Enum.group_by(& &1.currency)
      |> Enum.map(fn {currency, rows} ->
        base =
          rows
          |> Enum.reduce(Money.zero(scope.currency), fn invoice, acc ->
            converted =
              invoice
              |> outstanding_cents()
              |> Money.new(invoice.currency)
              |> Money.convert(scope.currency, invoice.fx_rate_to_base || Decimal.new(1))

            Money.add(acc, converted)
          end)

        {currency, base.amount}
      end)
      |> Enum.reject(fn {_currency, amount} -> amount == 0 end)

    case Enum.sum(Enum.map(totals, &elem(&1, 1))) do
      0 ->
        []

      grand ->
        totals
        |> Enum.map(fn {currency, amount} -> {currency, round(amount / grand * 100)} end)
        |> Enum.sort_by(&(-elem(&1, 1)))
    end
  end

  ## Presentation

  def statuses, do: Invoice.statuses()

  def status_label("partial"), do: "Part paid"
  def status_label("written_off"), do: "Written off"
  def status_label(status), do: status |> String.replace("_", " ") |> String.capitalize()

  def status_tone("paid"), do: "ok"
  def status_tone("overdue"), do: "bad"
  def status_tone("void"), do: "bad"
  def status_tone("written_off"), do: "bad"
  def status_tone("partial"), do: "warn"
  def status_tone(_other), do: ""

  def payout_tone("paid"), do: "ok"
  def payout_tone("approved"), do: "warn"
  def payout_tone("cancelled"), do: "bad"
  def payout_tone(_other), do: ""

  def money(cents, currency), do: cents |> Money.new(currency) |> Money.to_string()

  def invoice_total(%Invoice{} = invoice), do: money(invoice.total_cents, invoice.currency)

  def invoice_outstanding(%Invoice{} = invoice),
    do: money(outstanding_cents(invoice), invoice.currency)

  @doc """
  When it is due, said the way a person chases it.

  "22 Aug" tells you nothing without today's date in your head; "12 days
  overdue" is the thing being decided on.
  """
  def due_line(_scope, %Invoice{due_on: nil}, _today), do: "No due date"

  def due_line(scope, %Invoice{status: status} = invoice, _today)
      when status in ~w(paid void written_off),
      do: Formats.date(scope, invoice.due_on)

  def due_line(scope, %Invoice{} = invoice, today) do
    case Date.diff(invoice.due_on, today) do
      days when days < 0 -> "#{abs(days)} #{plural(abs(days))} overdue"
      0 -> "Due today"
      1 -> "Due tomorrow"
      days when days <= 14 -> "Due in #{days} days"
      _ -> "Due #{Formats.date(scope, invoice.due_on)}"
    end
  end

  def due_tone(%Invoice{status: status}) when status in ~w(paid void written_off), do: ""

  def due_tone(%Invoice{due_on: nil}), do: ""

  def due_tone(%Invoice{} = invoice) do
    if Date.compare(invoice.due_on, Date.utc_today()) == :lt, do: "bad", else: ""
  end

  defp plural(1), do: "day"
  defp plural(_), do: "days"

  def client_name(%Invoice{contact: %{name: name}}), do: name
  def client_name(%Invoice{}), do: "No contact linked"

  def payout_person(%{user: %{name: name}}), do: name
  def payout_person(_payout), do: "Unassigned"

  def payout_job(%{job: %{title: title}}), do: title
  def payout_job(_payout), do: "—"

  @doc "The exposure stat's detail line: the currencies behind the headline."
  def exposure_detail([]), do: "Nothing outstanding"

  def exposure_detail([_only]), do: "All in one currency"

  def exposure_detail(exposure) do
    exposure
    |> Enum.drop(1)
    |> Enum.map_join(" · ", fn {currency, percent} -> "#{currency} #{percent}%" end)
  end

  def exposure_headline([]), do: "—"
  def exposure_headline([{currency, percent} | _]), do: "#{currency} #{percent}%"
end
