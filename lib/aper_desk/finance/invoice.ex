defmodule AperDesk.Finance.Invoice do
  @moduledoc """
  A request for money.

  `paid_cents` is maintained by the payments context inside the same transaction
  as the payment that changes it, so an invoice can never claim to be paid
  without a payment row backing the claim.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Crm.{Contact, Lead}
  alias AperDesk.Finance.{InvoiceLineItem, Payment}
  alias AperDesk.Sales.Quote
  alias AperDesk.Scheduling.Job

  @kinds ~w(deposit balance full extra credit_note)
  @statuses ~w(draft sent partial paid overdue void written_off)
  @outstanding_statuses ~w(sent partial overdue)

  schema "invoices" do
    belongs_to :studio, Studio
    belongs_to :contact, Contact
    belongs_to :lead, Lead
    belongs_to :job, Job
    belongs_to :quote, Quote

    field :reference, :string, read_after_writes: true
    field :kind, :string, default: "balance"
    field :status, :string, default: "draft"

    field :currency, :string, default: "USD"
    field :fx_rate_to_base, :decimal, default: Decimal.new(1)
    field :subtotal_cents, :integer, default: 0
    field :discount_cents, :integer, default: 0
    field :tax_cents, :integer, default: 0
    field :total_cents, :integer, default: 0
    field :paid_cents, :integer, default: 0

    field :issued_on, :date
    field :due_on, :date
    field :notes, :string
    field :purchase_order, :string

    field :share_token_hash, :binary
    field :sent_at, :utc_datetime_usec
    field :paid_at, :utc_datetime_usec
    field :voided_at, :utc_datetime_usec
    field :written_off_at, :utc_datetime_usec
    field :reminders_sent, :integer, default: 0
    field :last_reminder_at, :utc_datetime_usec

    has_many :line_items, InvoiceLineItem, on_replace: :delete
    has_many :payments, Payment

    timestamps()
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
  def outstanding_statuses, do: @outstanding_statuses

  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :studio_id,
      :contact_id,
      :lead_id,
      :job_id,
      :quote_id,
      :reference,
      :kind,
      :status,
      :currency,
      :fx_rate_to_base,
      :discount_cents,
      :tax_cents,
      :issued_on,
      :due_on,
      :notes,
      :purchase_order
    ])
    |> validate_required([:studio_id, :currency])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:currency, AperDesk.Money.supported_currencies())
    |> cast_assoc(:line_items)
    |> recalculate_totals()
    |> unique_constraint([:studio_id, :reference])
  end

  def recalculate_totals(changeset) do
    items =
      changeset
      |> get_field(:line_items)
      |> List.wrap()
      |> Enum.reject(&match?(%{action: :replace}, &1))

    subtotal = Enum.reduce(items, 0, &(&2 + (&1.total_cents || 0)))
    discount = get_field(changeset, :discount_cents) || 0
    tax = get_field(changeset, :tax_cents) || 0

    changeset
    |> put_change(:subtotal_cents, subtotal)
    |> put_change(:total_cents, max(subtotal - discount + tax, 0))
  end

  def total(%__MODULE__{} = inv), do: AperDesk.Money.new(inv.total_cents, inv.currency)
  def paid(%__MODULE__{} = inv), do: AperDesk.Money.new(inv.paid_cents, inv.currency)

  def outstanding(%__MODULE__{} = inv),
    do: AperDesk.Money.new(max(inv.total_cents - inv.paid_cents, 0), inv.currency)

  @doc "Overdue means money is owed and the due date has passed. Void never counts."
  def overdue?(%__MODULE__{status: status}, _today)
      when status in ~w(paid void written_off draft),
      do: false

  def overdue?(%__MODULE__{due_on: nil}, _today), do: false

  def overdue?(%__MODULE__{due_on: due, total_cents: total, paid_cents: paid}, today),
    do: paid < total and Date.compare(today, due) == :gt

  @doc "The status a payment leaves the invoice in."
  def status_after_payment(%__MODULE__{total_cents: total}, paid_cents) when paid_cents >= total,
    do: "paid"

  def status_after_payment(%__MODULE__{}, paid_cents) when paid_cents > 0, do: "partial"
  def status_after_payment(%__MODULE__{status: status}, _paid), do: status
end

defmodule AperDesk.Finance.InvoiceLineItem do
  @moduledoc "One billed line. Tax is per-line because rates differ by item in most of Europe."
  use AperDesk.Schema

  schema "invoice_line_items" do
    belongs_to :invoice, AperDesk.Finance.Invoice
    field :description, :string
    field :quantity, :decimal, default: Decimal.new(1)
    field :unit_price_cents, :integer, default: 0
    field :total_cents, :integer, default: 0
    field :tax_rate_bps, :integer, default: 0
    field :position, :integer, default: 0
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:description, :quantity, :unit_price_cents, :tax_rate_bps, :position])
    |> validate_required([:description])
    |> validate_number(:tax_rate_bps, greater_than_or_equal_to: 0, less_than: 10_000)
    |> put_total()
  end

  defp put_total(changeset) do
    quantity = get_field(changeset, :quantity) || Decimal.new(1)
    unit = get_field(changeset, :unit_price_cents) || 0

    total =
      unit
      |> AperDesk.Money.new("USD")
      |> AperDesk.Money.multiply(quantity)
      |> Map.fetch!(:amount)

    put_change(changeset, :total_cents, total)
  end
end

defmodule AperDesk.Finance.Payment do
  @moduledoc """
  Money actually received.

  `provider` + `provider_reference` is uniquely indexed, which is what makes
  replayed Stripe webhooks harmless: the second attempt to record the same
  charge violates the index rather than double-crediting the invoice.
  """
  use AperDesk.Schema

  @methods ~w(card bank_transfer cash cheque stripe paypal other)
  @statuses ~w(pending succeeded failed refunded partially_refunded)

  schema "payments" do
    belongs_to :studio, AperDesk.Accounts.Studio
    belongs_to :invoice, AperDesk.Finance.Invoice

    field :amount_cents, :integer
    field :currency, :string
    field :fx_rate_to_base, :decimal, default: Decimal.new(1)
    field :method, :string, default: "card"
    field :status, :string, default: "succeeded"
    field :provider, :string
    field :provider_reference, :string
    field :received_at, :utc_datetime_usec
    field :fee_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :note, :string

    timestamps()
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :studio_id,
      :invoice_id,
      :amount_cents,
      :currency,
      :fx_rate_to_base,
      :method,
      :status,
      :provider,
      :provider_reference,
      :received_at,
      :fee_cents,
      :note
    ])
    |> validate_required([:studio_id, :amount_cents, :currency, :received_at])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_inclusion(:method, @methods)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:provider, :provider_reference],
      message: "this payment has already been recorded"
    )
  end
end

defmodule AperDesk.Finance.Payout do
  @moduledoc "What the studio owes a second shooter, editor or assistant for a job."
  use AperDesk.Schema

  @statuses ~w(pending approved paid cancelled)

  schema "payouts" do
    belongs_to :studio, AperDesk.Accounts.Studio
    belongs_to :user, AperDesk.Accounts.User
    belongs_to :job, AperDesk.Scheduling.Job
    belongs_to :assignment, AperDesk.Scheduling.Assignment
    belongs_to :approved_by, AperDesk.Accounts.User

    field :reference, :string, read_after_writes: true
    field :description, :string
    field :amount_cents, :integer
    field :currency, :string
    field :status, :string, default: "pending"
    field :approved_at, :utc_datetime_usec
    field :paid_at, :utc_datetime_usec
    # Groups payouts approved together, so a Friday payout run is one object.
    field :run_id, :binary_id

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(payout, attrs) do
    payout
    |> cast(attrs, [
      :studio_id,
      :user_id,
      :job_id,
      :assignment_id,
      :reference,
      :description,
      :amount_cents,
      :currency,
      :status,
      :run_id
    ])
    |> validate_required([:studio_id, :amount_cents, :currency])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:studio_id, :reference])
  end

  def amount(%__MODULE__{} = p), do: AperDesk.Money.new(p.amount_cents, p.currency)
end

defmodule AperDesk.Finance.Expense do
  @moduledoc "A cost, optionally attached to the job it was incurred for."
  use AperDesk.Schema

  @categories ~w(travel accommodation equipment software crew props print marketing other)

  schema "expenses" do
    belongs_to :studio, AperDesk.Accounts.Studio
    belongs_to :job, AperDesk.Scheduling.Job
    belongs_to :user, AperDesk.Accounts.User

    field :category, :string, default: "other"
    field :description, :string
    field :amount_cents, :integer
    field :currency, :string
    field :fx_rate_to_base, :decimal, default: Decimal.new(1)
    field :incurred_on, :date
    field :billable, :boolean, default: false
    field :receipt_url, :string

    timestamps()
  end

  def categories, do: @categories

  def changeset(expense, attrs) do
    expense
    |> cast(attrs, [
      :studio_id,
      :job_id,
      :user_id,
      :category,
      :description,
      :amount_cents,
      :currency,
      :fx_rate_to_base,
      :incurred_on,
      :billable,
      :receipt_url
    ])
    |> validate_required([:studio_id, :description, :amount_cents, :currency, :incurred_on])
    |> validate_inclusion(:category, @categories)
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
