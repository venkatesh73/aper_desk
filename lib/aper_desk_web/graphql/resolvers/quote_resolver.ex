defmodule AperDeskWeb.Graphql.Resolvers.QuoteResolver do
  @moduledoc """
  Quotes, including the margin view.

  `margin_percent` is what the studio keeps after crew payouts. It is computed
  here rather than shown as a line item because it is the number that decides
  whether a booking is worth taking, and it is not visible from the line items
  alone.
  """

  import Ecto.Query

  alias AperDesk.Repo
  alias AperDesk.Sales
  alias AperDesk.Sales.Quote
  alias AperDesk.Scoped
  alias AperDeskWeb.Graphql.Resolvers.Helpers

  def get(_parent, %{id: id}, %{context: %{scope: scope}}) do
    with {:ok, quote} <- Sales.fetch_quote(scope, id) do
      {:ok, shape(quote, crew_cost(scope, quote))}
    end
  end

  def open_quotes(_parent, _args, %{context: %{scope: scope}}) do
    with {:ok, quotes} <- Sales.list_quotes(scope) do
      {:ok,
       quotes
       |> Enum.filter(&(&1.status in Quote.open_statuses()))
       |> Enum.map(
         &%{
           id: &1.id,
           reference: &1.reference,
           client_name: (&1.contact && &1.contact.name) || &1.title
         }
       )}
    end
  end

  def send_quote(_parent, %{id: id}, %{context: %{scope: scope}}) do
    case Sales.send_quote(scope, id) do
      {:ok, quote, _token} ->
        {:ok, %{quote: shape(quote, 0), errors: []}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:ok, %{quote: nil, errors: changeset_errors(changeset)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp shape(%Quote{} = quote, crew_cost_cents) do
    quote = Repo.preload(quote, [:line_items, :contact, :lead])
    currency = quote.currency || "USD"
    client_pays = quote.total_cents || 0

    %{
      id: quote.id,
      reference: quote.reference,
      client_name: (quote.contact && quote.contact.name) || quote.title,
      client_email: quote.contact && quote.contact.email,
      shoot_date_label: quote.lead && Helpers.date_label(quote.lead.desired_date),
      client_currency: currency,
      status: quote.status,
      package_options: [],
      package_note: quote.client_note,
      line_items:
        Enum.map(quote.line_items, fn item ->
          %{
            id: item.id,
            label: item.description,
            qty: to_float(item.quantity),
            amount_usd: Helpers.to_major(item.total_cents, currency)
          }
        end),
      crew: [],
      terms: %{
        deposit: Helpers.to_major(quote.deposit_cents, currency) |> money_label(currency),
        balance_due: nil,
        expires_on: quote.valid_until && Date.to_iso8601(quote.valid_until),
        notes: quote.terms
      },
      totals: %{
        subtotal_usd: Helpers.to_major(quote.subtotal_cents, currency),
        discount_usd: Helpers.to_major(quote.discount_cents, currency),
        discount_label: nil,
        tax_usd: Helpers.to_major(quote.tax_cents, currency),
        tax_label: nil,
        client_pays_usd: Helpers.to_major(client_pays, currency),
        deposit_usd: Helpers.to_major(quote.deposit_cents, currency),
        crew_cost_usd: Helpers.to_major(crew_cost_cents, currency),
        margin_percent: margin(client_pays, crew_cost_cents)
      },
      readiness: readiness(quote)
    }
  end

  # Guarded against a zero total: a quote with nothing on it has no margin,
  # and dividing by zero to say so would take the whole screen down.
  defp margin(0, _crew), do: nil
  defp margin(nil, _crew), do: nil

  defp margin(client_pays, crew_cost) when client_pays > 0,
    do: Float.round((client_pays - crew_cost) / client_pays * 100, 1)

  defp margin(_client_pays, _crew), do: nil

  defp crew_cost(scope, %Quote{lead_id: nil}), do: tap(0, fn _ -> scope end)

  defp crew_cost(scope, %Quote{} = quote) do
    AperDesk.Finance.Payout
    |> Scoped.for_studio(scope)
    |> join(:inner, [p], j in AperDesk.Scheduling.Job, on: j.id == p.job_id)
    |> where([_p, j], j.lead_id == ^quote.lead_id)
    |> select([p], coalesce(sum(p.amount_cents), 0))
    |> Repo.one()
    |> case do
      %Decimal{} = d -> Decimal.to_integer(d)
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp readiness(%Quote{} = quote) do
    [
      %{label: "Client", detail: nil, state: state(quote.contact_id)},
      %{label: "Line items", detail: nil, state: state(quote.line_items != [])},
      %{label: "Valid until", detail: nil, state: state(quote.valid_until)},
      %{label: "Terms", detail: nil, state: state(quote.terms)},
      %{label: "Sent", detail: nil, state: state(quote.sent_at)}
    ]
  end

  defp state(nil), do: "todo"
  defp state(false), do: "todo"
  defp state(_), do: "done"

  defp money_label(nil, _currency), do: nil
  defp money_label(amount, currency), do: "#{amount} #{currency}"

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_integer(n), do: n / 1
  defp to_float(n) when is_float(n), do: n

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &%{field: to_string(field), message: &1})
    end)
  end
end
