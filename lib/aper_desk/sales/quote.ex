defmodule AperDesk.Sales.Quote do
  @moduledoc """
  A priced proposal.

  Once sent, a quote is a snapshot. It keeps its own line items and its own
  `fx_rate_to_base`, so re-opening a quote from March shows March's numbers even
  if the package has been re-priced twice since.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}
  alias AperDesk.Catalog.Package
  alias AperDesk.Crm.{Contact, Lead}
  alias AperDesk.Sales.QuoteLineItem

  @statuses ~w(draft sent viewed accepted declined expired)
  @open_statuses ~w(sent viewed)

  schema "quotes" do
    belongs_to :studio, Studio
    belongs_to :lead, Lead
    belongs_to :contact, Contact
    belongs_to :package, Package
    belongs_to :prepared_by, User

    field :reference, :string, read_after_writes: true
    field :status, :string, default: "draft"
    field :title, :string

    field :currency, :string, default: "USD"
    field :fx_rate_to_base, :decimal, default: Decimal.new(1)
    field :subtotal_cents, :integer, default: 0
    field :discount_cents, :integer, default: 0
    field :tax_cents, :integer, default: 0
    field :total_cents, :integer, default: 0
    field :deposit_cents, :integer, default: 0

    field :valid_until, :date
    field :terms, :string
    field :client_note, :string

    field :share_token_hash, :binary
    field :sent_at, :utc_datetime_usec
    field :first_viewed_at, :utc_datetime_usec
    field :view_count, :integer, default: 0
    field :accepted_at, :utc_datetime_usec
    field :declined_at, :utc_datetime_usec

    has_many :line_items, QuoteLineItem, foreign_key: :quote_id, on_replace: :delete

    timestamps()
  end

  def statuses, do: @statuses
  def open_statuses, do: @open_statuses

  def changeset(quote, attrs) do
    quote
    |> cast(attrs, [
      :studio_id,
      :lead_id,
      :contact_id,
      :package_id,
      :prepared_by_id,
      :reference,
      :status,
      :title,
      :currency,
      :fx_rate_to_base,
      :discount_cents,
      :valid_until,
      :terms,
      :client_note,
      :deposit_cents
    ])
    |> validate_required([:studio_id, :title, :currency])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:currency, AperDesk.Money.supported_currencies())
    |> cast_assoc(:line_items)
    |> recalculate_totals()
    |> unique_constraint([:studio_id, :reference])
  end

  @doc """
  Recompute subtotal, tax and total from the line items.

  Totals are never accepted from the client and never edited directly — they
  are always derived here, so a quote cannot disagree with its own lines.
  """
  def recalculate_totals(changeset) do
    items =
      changeset
      |> get_field(:line_items)
      |> List.wrap()
      |> Enum.reject(&match?(%{action: :replace}, &1))

    subtotal = Enum.reduce(items, 0, fn item, acc -> acc + (item.total_cents || 0) end)
    discount = get_field(changeset, :discount_cents) || 0
    tax = get_field(changeset, :tax_cents) || 0
    total = max(subtotal - discount + tax, 0)

    changeset
    |> put_change(:subtotal_cents, subtotal)
    |> put_change(:total_cents, total)
  end

  def total(%__MODULE__{} = q), do: AperDesk.Money.new(q.total_cents, q.currency)
  def deposit(%__MODULE__{} = q), do: AperDesk.Money.new(q.deposit_cents, q.currency)
end

defmodule AperDesk.Sales.QuoteLineItem do
  @moduledoc "One priced line on a quote. `total_cents` is derived, never supplied."
  use AperDesk.Schema

  schema "quote_line_items" do
    belongs_to :quote, AperDesk.Sales.Quote
    field :description, :string
    field :detail, :string
    field :quantity, :decimal, default: Decimal.new(1)
    field :unit_price_cents, :integer, default: 0
    field :total_cents, :integer, default: 0
    field :taxable, :boolean, default: true
    field :position, :integer, default: 0
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:description, :detail, :quantity, :unit_price_cents, :taxable, :position])
    |> validate_required([:description])
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
    |> put_line_total()
  end

  defp put_line_total(changeset) do
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
