defmodule AperDeskWeb.ClientQuoteLive do
  @moduledoc """
  The quote as the client sees it, opened from the link and nothing else.

  No account, no session — the share token is the whole authorisation, exactly
  as it is for a gallery. A quote that was never sent has no token at all, so
  there is nothing to guess at.

  Accepting from here is deliberately not wired to `Sales.accept_quote/2`: that
  function takes a `%Scope{}` and moves the lead to Booked, which is a studio
  action. The client presses a button that says so, and the studio confirms it
  from their own screen. A client cannot be allowed to move another studio's
  pipeline by opening a link.
  """

  use AperDeskWeb, :live_view

  alias AperDesk.Formats
  alias AperDesk.Money
  alias AperDesk.Sales
  alias AperDesk.Sales.Quote

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Sales.fetch_quote_by_token(token) do
      {:ok, quote} ->
        # Only a live quote is worth showing. An expired or already-decided one
        # would invite the client to act on a price that is no longer offered.
        if quote.status in ~w(sent viewed accepted declined) do
          # Counted on the connected mount only. A LiveView mounts twice, and
          # "opened 2 times" for a single visit is worse than not counting at
          # all — it is the number the studio decides whether to chase on.
          {:ok, quote} = if connected?(socket), do: record_view(quote), else: {:ok, quote}

          {:ok,
           socket
           |> assign(page_title: quote.title)
           |> assign(quote: quote)}
        else
          {:ok, assign(socket, quote: nil, page_title: "Quote")}
        end

      {:error, _reason} ->
        {:ok, assign(socket, quote: nil, page_title: "Quote")}
    end
  end

  # Viewing is recorded once per open, and only while the quote is still out.
  # Counting a view after acceptance would keep nudging the studio about a
  # quote that is already settled.
  defp record_view(%Quote{status: status} = quote) when status in ~w(sent viewed) do
    case Sales.record_quote_view(quote) do
      {:ok, viewed} ->
        {:ok, _} =
          viewed
          |> Ecto.Changeset.change(status: "viewed")
          |> AperDesk.Repo.update()
          |> case do
            {:ok, updated} ->
              {:ok, %{updated | line_items: quote.line_items, studio: quote.studio}}

            error ->
              error
          end

      _ ->
        {:ok, quote}
    end
  end

  defp record_view(quote), do: {:ok, quote}

  ## Presentation

  def money(cents, currency), do: cents |> Money.new(currency) |> Money.to_string(cents: true)

  def line_total(item, currency), do: money(item.total_cents || 0, currency)

  def quantity(item) do
    case item.quantity do
      nil -> "1"
      value -> value |> Decimal.normalize() |> Decimal.to_string(:normal)
    end
  end

  def decided?(%Quote{status: status}), do: status in ~w(accepted declined)

  @doc """
  How long the price is held for, in the studio's own date format.

  The client reads this, but it is the studio's document — showing an ISO
  timestamp to a couple choosing a wedding photographer is the wrong register,
  and guessing the reader's locale from nothing is worse.
  """
  def held_until(%Quote{valid_until: nil}), do: nil

  def held_until(%Quote{valid_until: date, studio: studio}),
    do: "This price is held until #{Formats.date(studio, date)}."
end
