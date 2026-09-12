defmodule AperDeskWeb.InvoiceLive do
  @moduledoc """
  One invoice: its lines, what has been paid against it, and what is left.

  The balance shown here is always `total − paid`, read from the row. It is
  never accumulated in the view, because `Finance.record_payment/3` recomputes
  `paid_cents` from the payment rows under a row lock — a second number derived
  a second way is a number that will eventually disagree.

  Recording a payment is the one action on this screen that can be raced: two
  people marking the same bank transfer received, or a webhook arriving while
  someone types. The context handles that; this form only has to not get in the
  way, so it submits the amount and lets the answer come back.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Crm
  alias AperDesk.Finance
  alias AperDesk.Finance.{Invoice, InvoiceTemplate}
  alias AperDesk.Formats
  alias AperDesk.Money

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, payment_amount: nil, payment_method: "bank_transfer")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns.current_scope
    blank = %Invoice{currency: scope.currency, line_items: []}

    socket
    |> assign(page_title: "New invoice")
    |> assign(invoice: blank)
    |> assign(contacts: contacts(scope))
    |> assign(templates: templates(scope))
    |> assign_form(Invoice.changeset(blank, %{}))
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case Finance.fetch_invoice(scope, id) do
      {:ok, invoice} ->
        socket
        |> assign(page_title: invoice.reference || "Invoice")
        |> assign(invoice: invoice)
        |> assign(contacts: contacts(scope))
        |> assign(templates: templates(scope))
        |> assign_form(Invoice.changeset(invoice, %{}))

      _ ->
        socket
        |> put_flash(:error, "That invoice is not here.")
        |> push_navigate(to: ~p"/app/finance")
    end
  end

  @impl true
  def handle_event("validate", %{"invoice" => params}, socket) do
    changeset =
      socket.assigns.invoice
      |> Invoice.changeset(to_cents(params, socket.assigns.invoice))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"invoice" => params}, socket) do
    attrs = to_cents(params, socket.assigns.invoice)
    scope = socket.assigns.current_scope

    case socket.assigns.live_action do
      :new ->
        case Finance.create_invoice(scope, attrs) do
          {:ok, invoice} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{invoice.reference} drafted.")
             |> push_navigate(to: ~p"/app/finance/invoices/#{invoice}")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign_form(socket, changeset)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not draft it: #{inspect(reason)}")}
        end

      :show ->
        case Finance.update_invoice(scope, socket.assigns.invoice.id, attrs) do
          {:ok, _invoice} ->
            {:noreply, socket |> refresh() |> put_flash(:info, "Saved.")}

          {:error, {:not_editable, status}} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "A #{String.downcase(status_label(status))} invoice cannot be re-priced — raise a credit note instead."
             )}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign_form(socket, changeset)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
        end
    end
  end

  @doc false
  # Fills in terms rather than replacing the invoice: whatever has already been
  # typed into the lines stays, because a studio picking a template halfway
  # through pricing meant "use these terms", not "start again".
  def handle_event("use-template", %{"id" => ""}, socket), do: {:noreply, socket}

  def handle_event("use-template", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Finance.fetch_invoice_template(scope, id) do
      {:ok, template} ->
        params =
          socket
          |> current_params()
          |> Map.merge(InvoiceTemplate.to_invoice_attrs(template, Formats.today_for(scope)))
          |> put_tax(template, socket)

        {:noreply,
         socket
         |> rebuild(params)
         |> put_flash(:info, "#{template.name} applied.")}

      _ ->
        {:noreply, put_flash(socket, :error, "That template is not here.")}
    end
  end

  def handle_event("add-line", _params, socket) do
    params = current_params(socket)
    lines = params |> Map.get("line_items", %{}) |> Map.new()
    next = to_string(map_size(lines))

    lines =
      Map.put(lines, next, %{"description" => "", "quantity" => "1", "unit_price_major" => ""})

    {:noreply, rebuild(socket, Map.put(params, "line_items", lines))}
  end

  def handle_event("remove-line", %{"index" => index}, socket) do
    params = current_params(socket)

    lines =
      params
      |> Map.get("line_items", %{})
      |> Map.delete(index)
      # Re-keyed from zero: Ecto reads these as an ordered map, and a gap in
      # the indices silently drops every line after it.
      |> Enum.sort_by(fn {key, _} -> String.to_integer(key) end)
      |> Enum.with_index()
      |> Map.new(fn {{_old, line}, position} -> {to_string(position), line} end)

    {:noreply, rebuild(socket, Map.put(params, "line_items", lines))}
  end

  def handle_event("send", _params, socket) do
    case Finance.send_invoice(socket.assigns.current_scope, socket.assigns.invoice.id) do
      {:ok, _invoice} ->
        {:noreply,
         socket
         |> refresh()
         |> put_flash(:info, "Issued. The FX rate in force today is stamped on it.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not issue it: #{inspect(reason)}")}
    end
  end

  def handle_event("payment-change", %{"payment" => params}, socket) do
    {:noreply,
     assign(socket,
       payment_amount: params["amount_major"],
       payment_method: params["method"] || socket.assigns.payment_method
     )}
  end

  def handle_event("record-payment", %{"payment" => params}, socket) do
    invoice = socket.assigns.invoice

    attrs = %{
      "amount_cents" => Money.from_major(params["amount_major"], invoice.currency),
      "currency" => invoice.currency,
      "method" => params["method"] || "bank_transfer",
      "received_at" => DateTime.utc_now(),
      "note" => params["note"]
    }

    case Finance.record_payment(socket.assigns.current_scope, invoice.id, attrs) do
      {:ok, %{invoice: updated}} ->
        {:noreply,
         socket
         |> assign(payment_amount: nil)
         |> refresh()
         |> put_flash(:info, paid_message(updated))}

      {:error, :already_recorded} ->
        {:noreply, put_flash(socket, :error, "That payment is already on this invoice.")}

      {:error, {:currency_mismatch, _, _}} ->
        {:noreply,
         put_flash(socket, :error, "A payment has to be in the invoice's own currency.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, first_error(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not record it: #{inspect(reason)}")}
    end
  end

  ## Internals

  # Tax is a rate on the template and an amount on the invoice, so it is worked
  # out against whatever the lines currently come to — applying a template
  # before pricing and after must not give different answers.
  defp put_tax(params, template, socket) do
    currency = params["currency"] || socket.assigns.invoice.currency
    subtotal = subtotal_of(params, socket)
    cents = InvoiceTemplate.tax_on(template, subtotal, currency)

    params
    |> Map.put("tax_cents", cents)
    |> Map.put("tax_major", Money.to_major(cents, currency))
  end

  defp subtotal_of(params, socket) do
    currency = params["currency"] || socket.assigns.invoice.currency

    params
    |> Map.get("line_items", %{})
    |> Enum.reduce(0, fn {_index, line}, total ->
      quantity =
        case Decimal.parse(to_string(line["quantity"] || "1")) do
          {decimal, _} -> decimal
          :error -> Decimal.new(1)
        end

      unit = Money.from_major(line["unit_price_major"], currency)

      total +
        (unit
         |> Money.new(currency)
         |> Money.multiply(quantity)
         |> Map.fetch!(:amount))
    end)
  end

  defp paid_message(%Invoice{status: "paid"}), do: "Paid in full."

  defp paid_message(%Invoice{} = invoice),
    do: "Recorded. #{money(outstanding_cents(invoice), invoice.currency)} still outstanding."

  defp first_error(%Ecto.Changeset{errors: [{field, {message, _}} | _]}),
    do: "#{field |> to_string() |> String.replace("_", " ") |> String.capitalize()} #{message}."

  defp first_error(_changeset), do: "That payment would not save."

  defp refresh(socket) do
    case Finance.fetch_invoice(socket.assigns.current_scope, socket.assigns.invoice.id) do
      {:ok, invoice} ->
        socket
        |> assign(invoice: invoice)
        |> assign_form(Invoice.changeset(invoice, %{}))

      _ ->
        socket
    end
  end

  defp assign_form(socket, changeset) do
    socket
    |> assign(form: to_form(changeset, as: :invoice))
    |> assign(preview: preview(changeset, socket.assigns.invoice))
  end

  defp preview(changeset, invoice) do
    applied = Ecto.Changeset.apply_changes(changeset)
    currency = applied.currency || invoice.currency

    %{
      subtotal: Money.new(applied.subtotal_cents || 0, currency),
      discount: Money.new(applied.discount_cents || 0, currency),
      tax: Money.new(applied.tax_cents || 0, currency),
      total: Money.new(applied.total_cents || 0, currency)
    }
  end

  defp rebuild(socket, params) do
    changeset =
      socket.assigns.invoice
      |> Invoice.changeset(to_cents(params, socket.assigns.invoice))
      |> Map.put(:action, :validate)

    assign_form(socket, changeset)
  end

  defp current_params(socket) do
    case socket.assigns.form.source.params do
      params when is_map(params) and map_size(params) > 0 -> params
      _ -> params_from(socket.assigns.invoice)
    end
  end

  defp params_from(%Invoice{} = invoice) do
    %{
      "discount_major" => Money.to_major(invoice.discount_cents, invoice.currency),
      "tax_major" => Money.to_major(invoice.tax_cents, invoice.currency),
      "line_items" =>
        invoice.line_items
        |> List.wrap()
        |> Enum.with_index()
        |> Map.new(fn {item, index} ->
          {to_string(index),
           %{
             "id" => item.id,
             "description" => item.description,
             "quantity" => to_string(item.quantity),
             "unit_price_major" => Money.to_major(item.unit_price_cents, invoice.currency)
           }}
        end)
    }
  end

  defp to_cents(params, %Invoice{} = invoice) do
    currency = params["currency"] || invoice.currency

    params
    |> put_cents("discount_major", "discount_cents", currency)
    |> put_cents("tax_major", "tax_cents", currency)
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

  defp templates(scope) do
    case Finance.list_invoice_templates(scope) do
      {:ok, templates} -> templates
      _ -> []
    end
  end

  defp contacts(scope) do
    case Crm.list_contacts(scope, limit: 200) do
      {:ok, contacts} -> contacts
      _ -> []
    end
  end

  defp outstanding_cents(%Invoice{} = invoice),
    do: max(invoice.total_cents - invoice.paid_cents, 0)

  ## Presentation

  defdelegate status_label(status), to: AperDeskWeb.FinanceLive
  defdelegate status_tone(status), to: AperDeskWeb.FinanceLive
  defdelegate client_name(invoice), to: AperDeskWeb.FinanceLive
  defdelegate contact_options(contacts), to: AperDeskWeb.QuotesLive
  defdelegate currency_options, to: AperDeskWeb.QuotesLive

  def money(cents, currency), do: cents |> Money.new(currency) |> Money.to_string(cents: true)

  def outstanding(%Invoice{} = invoice), do: money(outstanding_cents(invoice), invoice.currency)

  def editable?(%Invoice{status: status}), do: status == "draft"

  def kind_options,
    do: Enum.map(Invoice.kinds(), &{&1 |> String.replace("_", " ") |> String.capitalize(), &1})

  def method_options,
    do:
      Enum.map(
        ~w(bank_transfer card cash cheque stripe paypal other),
        &{&1 |> String.replace("_", " ") |> String.capitalize(), &1}
      )

  def payment_line(scope, payment) do
    "#{Formats.date(scope, payment.received_at)} · #{String.replace(payment.method, "_", " ")}"
  end

  @doc "What is left to pay, as the amount field's starting value."
  def suggested_payment(%Invoice{} = invoice),
    do: Money.to_major(outstanding_cents(invoice), invoice.currency)

  def template_options(templates),
    do: Enum.map(templates, &{&1.name <> if(&1.is_default, do: " · default", else: ""), &1.id})
end
