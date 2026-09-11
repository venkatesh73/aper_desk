defmodule AperDeskWeb.QuotesLive do
  @moduledoc """
  Every quote the studio has out, and the form that starts a new one.

  The list leads with what a quote is *doing* rather than when it was made: a
  quote nobody has opened after a week is a different problem from one the
  client read three times and did not accept, and both are different from one
  that quietly expires on Friday. That is the column a studio scans.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Crm
  alias AperDesk.Formats
  alias AperDesk.Money
  alias AperDesk.Sales
  alias AperDesk.Sales.Quote

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, status: nil)}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: "Quotes")
    |> load_quotes()
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns.current_scope

    socket
    |> assign(page_title: "New quote")
    |> assign(contacts: contacts(scope))
    |> assign(form: to_form(blank_changeset(scope), as: :quote))
  end

  @impl true
  def handle_event("status", %{"status" => status}, socket) do
    status = if status == "", do: nil, else: status
    {:noreply, socket |> assign(status: status) |> load_quotes()}
  end

  def handle_event("validate", %{"quote" => params}, socket) do
    changeset =
      %Quote{}
      |> Quote.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :quote))}
  end

  def handle_event("save", %{"quote" => params}, socket) do
    scope = socket.assigns.current_scope

    case Sales.create_quote(scope, Map.put_new(params, "currency", scope.currency)) do
      {:ok, quote} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{quote.reference} started. Price it up next.")
         |> push_navigate(to: ~p"/app/quotes/#{quote}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :quote))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start it: #{inspect(reason)}")}
    end
  end

  ## Data

  defp load_quotes(socket) do
    scope = socket.assigns.current_scope
    opts = if socket.assigns.status, do: [status: socket.assigns.status], else: []

    quotes =
      case Sales.list_quotes(scope, opts) do
        {:ok, list} -> list
        _ -> []
      end

    socket
    |> assign(quotes: quotes)
    |> assign(open_value: open_value(scope, quotes))
  end

  # What is actually in play: the total of everything sent and not yet decided.
  # Summed per currency and converted with each quote's own stored rate, for
  # the same reason `Finance.outstanding_total/1` does — a mixed-currency list
  # summed after conversion totals wrong.
  defp open_value(scope, quotes) do
    quotes
    |> Enum.filter(&(&1.status in Quote.open_statuses()))
    |> Enum.reduce(Money.zero(scope.currency), fn quote, acc ->
      converted =
        quote.total_cents
        |> Money.new(quote.currency)
        |> Money.convert(scope.currency, quote.fx_rate_to_base || Decimal.new(1))

      Money.add(acc, converted)
    end)
  end

  defp contacts(scope) do
    case Crm.list_contacts(scope, limit: 200) do
      {:ok, contacts} -> contacts
      _ -> []
    end
  end

  defp blank_changeset(scope),
    do: Quote.changeset(%Quote{currency: scope.currency}, %{})

  ## Presentation

  def statuses, do: Quote.statuses()

  def status_label("draft"), do: "Draft"
  def status_label("sent"), do: "Sent"
  def status_label("viewed"), do: "Opened"
  def status_label("accepted"), do: "Accepted"
  def status_label("declined"), do: "Declined"
  def status_label("expired"), do: "Expired"
  def status_label(other), do: String.capitalize(other)

  def status_tone("accepted"), do: "ok"
  def status_tone("viewed"), do: "warn"
  def status_tone("declined"), do: "bad"
  def status_tone("expired"), do: "bad"
  def status_tone(_other), do: ""

  @doc """
  What this quote is waiting on, in one line.

  This is the column the list exists for. "Sent 9 days ago, unopened" and
  "opened 3 times, no answer" call for different things, and a date alone says
  neither.
  """
  def waiting_on(scope, quote, today \\ nil)

  def waiting_on(_scope, %Quote{status: "draft"}, _today), do: "Not sent yet"

  def waiting_on(_scope, %Quote{status: "accepted"}, _today), do: "Accepted — raise the invoice"

  def waiting_on(_scope, %Quote{status: "declined"}, _today), do: "Declined"

  def waiting_on(scope, %Quote{status: "expired"} = quote, _today),
    do: "Expired #{Formats.date(scope, quote.valid_until)}"

  def waiting_on(_scope, %Quote{status: "sent"} = quote, today),
    do: "Sent #{ago(quote.sent_at, today)} · not opened"

  def waiting_on(_scope, %Quote{status: "viewed"} = quote, today) do
    "Opened #{quote.view_count} #{if quote.view_count == 1, do: "time", else: "times"} · last #{ago(quote.first_viewed_at, today)}"
  end

  def waiting_on(_scope, _quote, _today), do: "—"

  @doc "A tone for the waiting line, so a quote going stale reads as one."
  def waiting_tone(%Quote{status: status}) when status in ~w(declined expired), do: "bad"

  def waiting_tone(%Quote{status: "sent", sent_at: sent_at}) when not is_nil(sent_at) do
    if DateTime.diff(DateTime.utc_now(), sent_at, :day) >= 7, do: "bad", else: ""
  end

  def waiting_tone(_quote), do: ""

  @doc "How long ago, coarsely — nobody needs minutes on a quote."
  def ago(nil, _today), do: "—"

  def ago(%DateTime{} = at, _today) do
    case DateTime.diff(DateTime.utc_now(), at, :day) do
      0 -> "today"
      1 -> "yesterday"
      days when days < 14 -> "#{days} days ago"
      days when days < 60 -> "#{div(days, 7)} weeks ago"
      days -> "#{div(days, 30)} months ago"
    end
  end

  def total(%Quote{} = quote), do: quote |> Quote.total() |> Money.to_string()

  def client_name(%Quote{contact: %{name: name}}), do: name
  def client_name(%Quote{}), do: "No contact linked"

  def contact_options(contacts), do: Enum.map(contacts, &{&1.name, &1.id, &1.email})

  def currency_options,
    do: Enum.map(Money.supported_currencies(), &{"#{&1} · #{Money.symbol(&1)}", &1})
end
