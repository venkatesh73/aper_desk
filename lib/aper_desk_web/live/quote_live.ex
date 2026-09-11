defmodule AperDeskWeb.QuoteLive do
  @moduledoc """
  One quote: its lines, its terms, and the link the client opens.

  Line items are edited through the changeset rather than as loose assigns, so
  the running total in the summary is the same number `Quote.recalculate_totals/1`
  will store — a quote that showed one figure while typing and saved another
  would be worse than one that showed nothing.

  Money is typed in major units and converted once, on the way into the
  changeset. Everything below that boundary is integer minor units; see
  `AperDesk.Money`.

  Editing stops when the quote does. `Sales.update_quote/3` refuses anything
  past `sent`, so an accepted quote cannot be re-priced under the client — the
  form is read-only there rather than offering an action that would be refused.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Crm
  alias AperDesk.Formats
  alias AperDesk.Money
  alias AperDesk.Sales
  alias AperDesk.Sales.Quote

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Sales.fetch_quote(scope, id) do
      {:ok, quote} ->
        {:ok,
         socket
         |> assign(page_title: quote.reference || "Quote")
         |> assign(quote: quote, share_token: nil)
         |> assign(contacts: contacts(scope))
         |> assign(open_quotes: open_quotes(scope, quote))
         |> assign_form(Quote.changeset(quote, %{}))}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That quote is not here.")
         |> push_navigate(to: ~p"/app/quotes")}
    end
  end

  @impl true
  def handle_event("validate", %{"quote" => params}, socket) do
    changeset =
      socket.assigns.quote
      |> Quote.changeset(to_cents(params, socket.assigns.quote))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"quote" => params}, socket) do
    save(socket, to_cents(params, socket.assigns.quote))
  end

  # A line is added to the params the form already holds rather than to the
  # saved quote, so an unsaved edit two fields up is not thrown away by
  # pressing "add a line".
  def handle_event("add-line", _params, socket) do
    params = current_params(socket)
    lines = params |> Map.get("line_items", %{}) |> Map.new()
    next = to_string(map_size(lines))

    lines =
      Map.put(lines, next, %{
        "description" => "",
        "quantity" => "1",
        "unit_price_major" => "",
        "position" => next
      })

    {:noreply, rebuild(socket, Map.put(params, "line_items", lines))}
  end

  def handle_event("remove-line", %{"index" => index}, socket) do
    params = current_params(socket)

    lines =
      params
      |> Map.get("line_items", %{})
      |> Map.delete(index)
      # Re-key from zero: Ecto reads these as an ordered map, and a gap in the
      # indices silently drops every line after it.
      |> Enum.sort_by(fn {key, _} -> String.to_integer(key) end)
      |> Enum.with_index()
      |> Map.new(fn {{_old, line}, position} -> {to_string(position), line} end)

    {:noreply, rebuild(socket, Map.put(params, "line_items", lines))}
  end

  def handle_event("send", _params, socket) do
    case Sales.send_quote(socket.assigns.current_scope, socket.assigns.quote.id) do
      {:ok, _quote, token} ->
        {:noreply,
         socket
         |> assign(share_token: token)
         |> refresh()
         |> put_flash(:info, "Sent. Copy the link now — it is not shown again.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not send it: #{inspect(reason)}")}
    end
  end

  def handle_event("accept", _params, socket) do
    case Sales.accept_quote(socket.assigns.current_scope, socket.assigns.quote.id) do
      {:ok, _quote} ->
        {:noreply,
         socket |> refresh() |> put_flash(:info, "Marked accepted. The lead moved to Booked.")}

      {:error, {:not_open, status}} ->
        {:noreply,
         put_flash(socket, :error, "This quote is #{status_label(status)} — nothing to accept.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not accept it: #{inspect(reason)}")}
    end
  end

  def handle_event("decline", _params, socket) do
    case Sales.decline_quote(socket.assigns.current_scope, socket.assigns.quote.id) do
      {:ok, _quote} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Marked declined.")}

      {:error, {:not_open, status}} ->
        {:noreply,
         put_flash(socket, :error, "This quote is #{status_label(status)} — nothing to decline.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not decline it: #{inspect(reason)}")}
    end
  end

  ## Saving

  defp save(socket, attrs) do
    case Sales.update_quote(socket.assigns.current_scope, socket.assigns.quote.id, attrs) do
      {:ok, _quote} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Saved.")}

      {:error, {:not_editable, status}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "An #{status_label(status) |> String.downcase()} quote cannot be re-priced."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  # Every mutation goes back through `fetch_quote/2` rather than using what the
  # context handed back. The context returns the row it updated, which does not
  # carry `line_items` — and `Quote.changeset/2` casts them, so building a form
  # from an unloaded quote raises rather than rendering an empty list.
  defp refresh(socket) do
    case Sales.fetch_quote(socket.assigns.current_scope, socket.assigns.quote.id) do
      {:ok, quote} ->
        socket
        |> assign(quote: quote)
        |> assign_form(Quote.changeset(quote, %{}))

      _ ->
        socket
    end
  end

  # The summary has to show the total the save will write, so the changeset is
  # run through the same `recalculate_totals/1` the schema uses rather than the
  # view adding the lines up a second way.
  defp assign_form(socket, changeset) do
    socket
    |> assign(form: to_form(changeset, as: :quote))
    |> assign(preview: preview(changeset, socket.assigns.quote))
  end

  defp preview(changeset, quote) do
    applied = Ecto.Changeset.apply_changes(changeset)

    %{
      subtotal: Money.new(applied.subtotal_cents || 0, applied.currency || quote.currency),
      discount: Money.new(applied.discount_cents || 0, applied.currency || quote.currency),
      tax: Money.new(applied.tax_cents || 0, applied.currency || quote.currency),
      total: Money.new(applied.total_cents || 0, applied.currency || quote.currency),
      deposit: Money.new(applied.deposit_cents || 0, applied.currency || quote.currency)
    }
  end

  defp rebuild(socket, params) do
    changeset =
      socket.assigns.quote
      |> Quote.changeset(to_cents(params, socket.assigns.quote))
      |> Map.put(:action, :validate)

    assign_form(socket, changeset)
  end

  # The params the form is currently showing, whether they came from the
  # browser or from the saved quote.
  defp current_params(socket) do
    case socket.assigns.form.source.params do
      params when is_map(params) and map_size(params) > 0 -> params
      _ -> params_from(socket.assigns.quote)
    end
  end

  defp params_from(%Quote{} = quote) do
    %{
      "discount_major" => Money.to_major(quote.discount_cents, quote.currency),
      "tax_major" => Money.to_major(quote.tax_cents, quote.currency),
      "deposit_major" => Money.to_major(quote.deposit_cents, quote.currency),
      "line_items" =>
        quote.line_items
        |> Enum.sort_by(& &1.position)
        |> Enum.with_index()
        |> Map.new(fn {item, index} ->
          {to_string(index),
           %{
             "id" => item.id,
             "description" => item.description,
             "detail" => item.detail,
             "quantity" => to_string(item.quantity),
             "unit_price_major" => Money.to_major(item.unit_price_cents, quote.currency),
             "position" => to_string(index)
           }}
        end)
    }
  end

  # Major units in, minor units out — once, here. Everything downstream of this
  # function is integers.
  defp to_cents(params, %Quote{} = quote) do
    currency = params["currency"] || quote.currency

    params
    |> put_cents("discount_major", "discount_cents", currency)
    |> put_cents("tax_major", "tax_cents", currency)
    |> put_cents("deposit_major", "deposit_cents", currency)
    |> Map.update("line_items", %{}, fn lines ->
      Map.new(lines, fn {index, line} ->
        {index, put_cents(line, "unit_price_major", "unit_price_cents", currency)}
      end)
    end)
  end

  defp put_cents(params, from, to, currency) do
    case Map.fetch(params, from) do
      {:ok, value} -> Map.put(params, to, Money.from_major(value, currency))
      :error -> params
    end
  end

  ## Data

  defp contacts(scope) do
    case Crm.list_contacts(scope, limit: 200) do
      {:ok, contacts} -> contacts
      _ -> []
    end
  end

  # The sidebar doubles as navigation between the quotes actually in play, so a
  # studio chasing four of them does not go back to the list between each.
  defp open_quotes(scope, current) do
    case Sales.list_quotes(scope) do
      {:ok, quotes} ->
        quotes
        |> Enum.filter(&(&1.status in Quote.open_statuses() or &1.status == "draft"))
        |> Enum.reject(&(&1.id == current.id))
        |> Enum.take(8)

      _ ->
        []
    end
  end

  ## Presentation

  defdelegate status_label(status), to: AperDeskWeb.QuotesLive
  defdelegate status_tone(status), to: AperDeskWeb.QuotesLive
  defdelegate contact_options(contacts), to: AperDeskWeb.QuotesLive
  defdelegate currency_options, to: AperDeskWeb.QuotesLive

  @doc "Whether the quote can still be re-priced. Mirrors `Sales.update_quote/3`."
  def editable?(%Quote{status: status}), do: status in ~w(draft sent)

  def money(cents, currency), do: cents |> Money.new(currency) |> Money.to_string(cents: true)

  def share_url(token), do: url(~p"/q/#{token}")

  @doc """
  The deposit as a share of the total, which is the number a studio sanity-checks.

  Nil rather than 0% on an unpriced quote — "0%" reads as a decision.
  """
  def deposit_share(%{total: %{amount: 0}}), do: nil

  def deposit_share(%{total: total, deposit: deposit}),
    do: "#{round(deposit.amount / total.amount * 100)}% of the total"

  def valid_line(_scope, %Quote{valid_until: nil}), do: "No expiry set"

  def valid_line(scope, %Quote{valid_until: date}) do
    case Date.diff(date, Formats.today_for(scope)) do
      days when days < 0 -> "Expired #{Formats.date(scope, date)}"
      0 -> "Expires today"
      1 -> "Expires tomorrow"
      days -> "Expires in #{days} days · #{Formats.date(scope, date)}"
    end
  end
end
