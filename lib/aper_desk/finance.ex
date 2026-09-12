defmodule AperDesk.Finance do
  @moduledoc """
  Invoices, payments, payouts and expenses.

  Money is where correctness is least negotiable, so two rules hold throughout:

  **A payment and the balance it changes commit together.** `record_payment/3`
  takes `SELECT ... FOR UPDATE` on the invoice, inserts the payment, recomputes
  `paid_cents` from the payment rows, and writes the new status — all inside one
  transaction. Two payments landing at once (a card charge and a manual bank
  entry, say) are serialised by the lock, so the second reads the balance the
  first wrote instead of overwriting it. Recomputing from rows rather than
  incrementing means the stored balance can always be re-derived from the
  payments that justify it.

  **Replays are harmless.** Stripe delivers webhooks at-least-once and out of
  order. `(provider, provider_reference)` is uniquely indexed, so the second
  delivery of a charge hits the index and is reported as already recorded
  rather than crediting the invoice twice.

  Amounts are integer minor units throughout — never floats, at any point. See
  `AperDesk.Money`.
  """

  import Ecto.Query

  alias AperDesk.Authorization
  alias AperDesk.Events
  alias AperDesk.Finance.{Expense, FxRate, Invoice, Payment, Payout}
  alias AperDesk.Finance.InvoiceTemplate
  alias AperDesk.Money
  alias AperDesk.Repo
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias Ecto.Multi

  ## Invoices

  def list_invoices(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"invoice.read") do
      {:ok,
       Invoice
       |> Scoped.for_studio(scope)
       |> filter_invoices(opts)
       |> preload([:contact, :line_items])
       |> order_by([i], desc: i.inserted_at)
       |> Scoped.paginate(opts)
       |> Repo.all()}
    end
  end

  def fetch_invoice(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"invoice.read") do
      case Invoice
           |> Scoped.for_studio(scope)
           |> preload([:line_items, :payments, :contact])
           |> Repo.get(id) do
        nil -> {:error, :not_found}
        invoice -> {:ok, invoice}
      end
    end
  end

  def create_invoice(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"invoice.write") do
      Multi.new()
      |> Multi.insert(:invoice, Invoice.changeset(%Invoice{}, Scoped.put_studio(attrs, scope)))
      |> Events.log(:invoice, "invoice.created", "Invoice drafted", scope)
      |> Repo.transaction()
      |> unwrap(:invoice)
    end
  end

  @doc """
  Re-draft an invoice.

  Only a draft. Once an invoice is sent it is a document the client holds a
  copy of, and silently re-pricing it would leave the two disagreeing about
  what was owed — issue a credit note or a second invoice instead.

  Loaded through `fetch_invoice/2` so the line items come with it:
  `Invoice.changeset/2` casts them, and casting an unloaded association raises
  rather than quietly doing nothing.
  """
  def update_invoice(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"invoice.write"),
         {:ok, invoice} <- fetch_invoice(scope, id),
         :ok <- ensure_draft(invoice) do
      invoice |> Invoice.changeset(attrs) |> Repo.update()
    end
  end

  defp ensure_draft(%Invoice{status: "draft"}), do: :ok
  defp ensure_draft(%Invoice{status: status}), do: {:error, {:not_editable, status}}

  @doc """
  Issue an invoice to the client.

  Stamps the FX rate in force on the issue date. An issued document must always
  convert at the rate that applied when it was issued — re-converting at today's
  rate would restate last quarter's revenue every time the rate table refreshed.
  """
  def send_invoice(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"invoice.write"),
         {:ok, invoice} <- Scoped.fetch(Invoice, scope, id) do
      today = Date.utc_today()

      Multi.new()
      |> Multi.run(:rate, fn repo, _ ->
        {:ok, fx_rate(repo, invoice.currency, scope.currency, today)}
      end)
      |> Multi.update(:invoice, fn %{rate: rate} ->
        invoice
        |> Ecto.Changeset.change(
          status: "sent",
          sent_at: DateTime.utc_now(),
          issued_on: invoice.issued_on || today,
          fx_rate_to_base: rate
        )
      end)
      |> Events.record(:invoice, "invoice.sent", "Invoice sent to client", scope)
      |> Repo.transaction()
      |> unwrap(:invoice)
    end
  end

  ## Invoice templates

  def list_invoice_templates(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"invoice.read") do
      {:ok,
       InvoiceTemplate
       |> Scoped.for_studio(scope)
       |> then(fn q ->
         if Keyword.get(opts, :include_archived, false),
           do: q,
           else: where(q, [t], is_nil(t.archived_at))
       end)
       |> order_by([t], desc: t.is_default, asc: t.name)
       |> Repo.all()}
    end
  end

  def fetch_invoice_template(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"invoice.read") do
      Scoped.fetch(InvoiceTemplate, scope, id)
    end
  end

  @doc """
  Create a template, clearing any other default if this one claims it.

  Both writes share a transaction, because the unique index refuses two
  defaults and an unguarded insert would simply fail rather than doing the
  obvious thing — a studio ticking "use this one by default" means it, and
  should not have to go and untick the old one first.
  """
  def create_invoice_template(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"invoice.write") do
      Multi.new()
      |> demote_existing_default(scope, attrs)
      |> Multi.insert(
        :template,
        InvoiceTemplate.changeset(%InvoiceTemplate{}, Scoped.put_studio(attrs, scope))
      )
      |> Repo.transaction()
      |> unwrap(:template)
    end
  end

  def update_invoice_template(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"invoice.write"),
         {:ok, template} <- Scoped.fetch(InvoiceTemplate, scope, id) do
      Multi.new()
      |> demote_existing_default(scope, attrs, template.id)
      |> Multi.update(:template, InvoiceTemplate.changeset(template, attrs))
      |> Repo.transaction()
      |> unwrap(:template)
    end
  end

  @doc "Retire a template. Invoices raised from it are untouched."
  def archive_invoice_template(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"invoice.write"),
         {:ok, template} <- Scoped.fetch(InvoiceTemplate, scope, id) do
      template |> InvoiceTemplate.archive_changeset() |> Repo.update()
    end
  end

  @doc """
  The template to reach for, given a shoot type.

  A template matching the shoot type beats the studio's default, because a
  studio that has written terms specifically for weddings meant them to apply
  to weddings.
  """
  def default_invoice_template(%Scope{} = scope, shoot_type \\ nil) do
    with {:ok, templates} <- list_invoice_templates(scope) do
      {:ok,
       Enum.find(templates, &(shoot_type && &1.shoot_type == shoot_type)) ||
         Enum.find(templates, & &1.is_default)}
    end
  end

  defp demote_existing_default(multi, scope, attrs, keep_id \\ nil) do
    if attrs["is_default"] in [true, "true"] do
      Multi.update_all(
        multi,
        :demote,
        fn _changes ->
          InvoiceTemplate
          |> Scoped.for_studio(scope)
          |> where([t], t.is_default)
          |> then(fn q -> if keep_id, do: where(q, [t], t.id != ^keep_id), else: q end)
        end,
        set: [is_default: false]
      )
    else
      multi
    end
  end

  ## Payments

  @doc """
  Record money received against an invoice.

  Returns `{:ok, %{payment: payment, invoice: invoice}}`, or
  `{:error, :already_recorded}` when the same provider reference arrives twice.

  The whole operation is one transaction holding a row lock on the invoice, so
  concurrent payments cannot interleave into a wrong balance.
  """
  def record_payment(%Scope{} = scope, invoice_id, attrs) do
    with :ok <- Authorization.authorize(scope, :"payment.write") do
      Repo.transaction(fn ->
        with {:ok, invoice} <- lock_invoice(scope, invoice_id),
             :ok <- check_currency(invoice, attrs),
             {:ok, payment} <- insert_payment(scope, invoice, attrs),
             {:ok, invoice} <- refresh_balance(invoice) do
          emit_payment_events(scope, invoice, payment)
          %{payment: payment, invoice: invoice}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Apply a payment that arrived by webhook.

  Idempotency is enforced twice over: the caller records the provider's event id
  in `processed_webhook_events`, and this function's insert is guarded by the
  `(provider, provider_reference)` index. Either alone would be enough for the
  common case; both together survive the case where a webhook is redelivered
  under a fresh event id.
  """
  def apply_provider_payment(%Scope{} = scope, invoice_id, provider, reference, attrs) do
    record_payment(
      scope,
      invoice_id,
      Map.merge(attrs, %{"provider" => provider, "provider_reference" => reference})
    )
  end

  @doc """
  Refund part or all of a payment.

  The refund is recorded on the payment and the invoice balance recomputed in
  the same transaction, so an invoice can never show as paid on the strength of
  money that has since gone back.
  """
  def refund_payment(%Scope{} = scope, payment_id, amount_cents) when amount_cents > 0 do
    with :ok <- Authorization.authorize(scope, :"payment.write") do
      Repo.transaction(fn ->
        with {:ok, payment} <- Scoped.fetch(Payment, scope, payment_id),
             {:ok, invoice} <- lock_invoice(scope, payment.invoice_id),
             :ok <- check_refundable(payment, amount_cents),
             {:ok, payment} <- do_refund(payment, amount_cents),
             {:ok, invoice} <- refresh_balance(invoice) do
          %{payment: payment, invoice: invoice}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Invoices with money outstanding and a due date in the past."
  def overdue_invoices(%Scope{} = scope, today \\ Date.utc_today()) do
    with :ok <- Authorization.authorize(scope, :"invoice.read") do
      Invoice
      |> Scoped.for_studio(scope)
      |> where([i], i.status in ^Invoice.outstanding_statuses())
      |> where([i], not is_nil(i.due_on) and i.due_on < ^today)
      |> where([i], i.paid_cents < i.total_cents)
      |> preload([:contact])
      |> order_by([i], asc: i.due_on)
      |> Repo.all()
    end
  end

  @doc """
  Total outstanding, converted to the studio's base currency.

  Summed per currency and converted with each invoice's stored rate rather than
  summed after conversion, so a mixed-currency ledger totals correctly.
  """
  def outstanding_total(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"invoice.read") do
      Invoice
      |> Scoped.for_studio(scope)
      |> where([i], i.status in ^Invoice.outstanding_statuses())
      |> select([i], {i.currency, sum(i.total_cents - i.paid_cents), i.fx_rate_to_base})
      |> group_by([i], [i.currency, i.fx_rate_to_base])
      |> Repo.all()
      |> Enum.reduce(Money.zero(scope.currency), fn {currency, amount, rate}, acc ->
        converted =
          amount
          |> to_cents()
          |> Money.new(currency)
          |> Money.convert(scope.currency, rate || Decimal.new(1))

        Money.add(acc, converted)
      end)
    end
  end

  ## Payouts

  @doc """
  Approve payouts as one run.

  They share a `run_id` and one transaction, so a Friday payout run is a single
  auditable object rather than a scatter of rows that may or may not all have
  gone through.
  """
  def approve_payouts(%Scope{} = scope, payout_ids) when is_list(payout_ids) do
    with :ok <- Authorization.authorize(scope, :"payout.write") do
      run_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        {count, payouts} =
          Repo.update_all(
            from(p in Payout,
              where:
                p.id in ^payout_ids and p.studio_id == ^Scope.studio_id(scope) and
                  p.status == "pending",
              select: p
            ),
            set: [
              status: "approved",
              approved_at: now,
              approved_by_id: Scope.user_id(scope),
              run_id: run_id,
              updated_at: now
            ]
          )

        if count == length(payout_ids) do
          %{run_id: run_id, payouts: payouts}
        else
          # Some were already approved or belong to another studio. Approving a
          # partial run silently would leave crew unpaid with no signal.
          Repo.rollback({:not_all_pending, count, length(payout_ids)})
        end
      end)
    end
  end

  def list_payouts(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"payout.read") do
      {:ok,
       Payout
       |> Scoped.for_studio(scope)
       |> then(fn q ->
         case opts[:status] do
           nil -> q
           status -> where(q, [p], p.status == ^status)
         end
       end)
       |> preload([:user, :job])
       |> Repo.all()}
    end
  end

  ## Expenses

  def create_expense(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"expense.write") do
      %Expense{} |> Expense.changeset(Scoped.put_studio(attrs, scope)) |> Repo.insert()
    end
  end

  def list_expenses(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"expense.read") do
      {:ok,
       Expense
       |> Scoped.for_studio(scope)
       |> then(fn q ->
         case opts[:job_id] do
           nil -> q
           job_id -> where(q, [e], e.job_id == ^job_id)
         end
       end)
       |> order_by([e], desc: e.incurred_on)
       |> Repo.all()}
    end
  end

  ## FX

  @doc "Store a daily rate. Existing rates for the same day are never overwritten."
  def put_fx_rate(attrs), do: %FxRate{} |> FxRate.changeset(attrs) |> Repo.insert()

  @doc """
  The rate for a pair on a date, falling back to the most recent earlier one.

  Falling back rather than failing matters: rate feeds skip weekends and public
  holidays, and an invoice issued on a Sunday still has to be converted.
  """
  def fx_rate(repo \\ Repo, from_currency, to_currency, as_of)

  def fx_rate(_repo, currency, currency, _as_of), do: Decimal.new(1)

  def fx_rate(repo, from_currency, to_currency, as_of) do
    query =
      from f in FxRate,
        where:
          f.base_currency == ^from_currency and f.quote_currency == ^to_currency and
            f.as_of <= ^as_of,
        order_by: [desc: f.as_of],
        limit: 1,
        select: f.rate

    repo.one(query) || Decimal.new(1)
  end

  ## Internals

  defp lock_invoice(scope, invoice_id) do
    query =
      from i in Invoice,
        where: i.id == ^invoice_id and i.studio_id == ^Scope.studio_id(scope),
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, :not_found}
      invoice -> {:ok, invoice}
    end
  end

  # Recording a payment in a different currency from the invoice would make the
  # balance meaningless — 100 EUR against a 100 USD invoice is not "paid".
  defp check_currency(%Invoice{currency: currency}, attrs) do
    case attrs["currency"] || attrs[:currency] do
      nil -> :ok
      ^currency -> :ok
      other -> {:error, {:currency_mismatch, other, currency}}
    end
  end

  defp insert_payment(scope, invoice, attrs) do
    attrs =
      attrs
      |> Scoped.put_studio(scope)
      |> Map.put("invoice_id", invoice.id)
      |> Map.put_new("currency", invoice.currency)
      |> Map.put_new("received_at", DateTime.utc_now())

    case %Payment{} |> Payment.changeset(attrs) |> Repo.insert() do
      {:ok, payment} ->
        {:ok, payment}

      {:error, changeset} ->
        if duplicate_provider_reference?(changeset) do
          {:error, :already_recorded}
        else
          {:error, changeset}
        end
    end
  end

  # Recomputed from the payment rows rather than incremented, so the stored
  # balance is always re-derivable from the evidence behind it. A counter that
  # is only ever incremented cannot be audited or repaired.
  defp refresh_balance(%Invoice{} = invoice) do
    # Postgres returns sum() over bigint as numeric, which arrives as a Decimal.
    # Coerced back to an integer here so minor units never become a float or a
    # Decimal further downstream.
    paid =
      Repo.one(
        from p in Payment,
          where: p.invoice_id == ^invoice.id and p.status in ^["succeeded", "partially_refunded"],
          select: coalesce(sum(p.amount_cents - p.refunded_cents), 0)
      )
      |> to_cents()

    invoice
    |> Ecto.Changeset.change(
      paid_cents: paid,
      status: Invoice.status_after_payment(invoice, paid),
      paid_at: if(paid >= invoice.total_cents, do: invoice.paid_at || DateTime.utc_now())
    )
    |> Repo.update()
  end

  defp to_cents(nil), do: 0
  defp to_cents(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_cents(n) when is_integer(n), do: n

  defp check_refundable(%Payment{amount_cents: amount, refunded_cents: refunded}, requested) do
    if refunded + requested <= amount do
      :ok
    else
      {:error, {:refund_exceeds_payment, amount - refunded, requested}}
    end
  end

  defp do_refund(%Payment{} = payment, amount_cents) do
    refunded = payment.refunded_cents + amount_cents
    status = if refunded >= payment.amount_cents, do: "refunded", else: "partially_refunded"

    payment
    |> Ecto.Changeset.change(refunded_cents: refunded, status: status)
    |> Repo.update()
  end

  # Inside the transaction already, so these commit with the payment.
  defp emit_payment_events(scope, invoice, payment) do
    Events.emit_now(Repo, scope, "invoice.payment_received", invoice, %{
      "amount_cents" => payment.amount_cents,
      "currency" => payment.currency
    })

    if invoice.status == "paid" do
      Events.emit_now(Repo, scope, "invoice.paid", invoice, %{"currency" => invoice.currency})
    end
  end

  defp duplicate_provider_reference?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:provider, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      {:provider_reference, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp unwrap({:ok, changes}, key), do: {:ok, Map.fetch!(changes, key)}
  defp unwrap({:error, _step, %Ecto.Changeset{} = changeset, _}, _key), do: {:error, changeset}
  defp unwrap({:error, _step, reason, _}, _key), do: {:error, reason}

  defp filter_invoices(query, opts) do
    Enum.reduce(opts, query, fn
      {:status, status}, q -> where(q, [i], i.status == ^status)
      {:contact_id, id}, q -> where(q, [i], i.contact_id == ^id)
      {:job_id, id}, q -> where(q, [i], i.job_id == ^id)
      {:outstanding, true}, q -> where(q, [i], i.status in ^Invoice.outstanding_statuses())
      _, q -> q
    end)
  end
end
