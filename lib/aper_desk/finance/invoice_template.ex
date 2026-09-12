defmodule AperDesk.Finance.InvoiceTemplate do
  @moduledoc """
  Reusable invoice terms: when it is due, what tax applies, what the client is
  told about paying.

  Tax is a rate in basis points, not an amount. The amount depends on the
  invoice; the rate is the thing a studio decides once. Storing 23% as 2300
  rather than 0.23 keeps it an integer all the way down, for the same reason
  money is — see `AperDesk.Money`.

  `deposit_percent` only means anything on a deposit template, and is the
  share of the quote's total the studio asks for up front.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Finance.Invoice
  alias AperDesk.Money

  schema "invoice_templates" do
    belongs_to :studio, Studio

    field :name, :string
    field :shoot_type, :string
    field :kind, :string, default: "balance"

    field :due_in_days, :integer, default: 14
    field :tax_bps, :integer, default: 0
    field :tax_label, :string
    field :deposit_percent, :integer

    field :notes, :string
    field :payment_instructions, :string
    field :is_default, :boolean, default: false
    field :archived_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [
      :studio_id,
      :name,
      :shoot_type,
      :kind,
      :due_in_days,
      :tax_bps,
      :tax_label,
      :deposit_percent,
      :notes,
      :payment_instructions,
      :is_default
    ])
    |> validate_required([:studio_id, :name])
    |> validate_inclusion(:kind, Invoice.kinds())
    |> validate_number(:due_in_days, greater_than_or_equal_to: 0)
    |> validate_number(:tax_bps, greater_than_or_equal_to: 0, less_than_or_equal_to: 10_000)
    |> validate_number(:deposit_percent,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> unique_constraint(:is_default,
      name: :invoice_templates_one_default_per_studio,
      message: "another template is already the default"
    )
  end

  def archive_changeset(template), do: change(template, archived_at: DateTime.utc_now())

  @doc "The rate as a person writes it: `2300` -> `23%`."
  def tax_percent(%__MODULE__{tax_bps: nil}), do: 0
  def tax_percent(%__MODULE__{tax_bps: bps}), do: bps / 100

  @doc """
  The tax on a subtotal, at this template's rate.

  Rounded once, here, rather than at the line — a per-line rounding of 23% on
  seven lines and a rounding of the whole differ by pennies, and the client
  adds up the whole.
  """
  def tax_on(%__MODULE__{tax_bps: bps}, subtotal_cents, currency)
      when is_integer(subtotal_cents) do
    subtotal_cents
    |> Money.new(currency)
    |> Money.percent_bps(bps || 0)
    |> Map.fetch!(:amount)
  end

  @doc "What this template fills in on a new invoice, given the day it is raised."
  def to_invoice_attrs(%__MODULE__{} = template, today \\ Date.utc_today()) do
    %{
      "kind" => template.kind,
      "issued_on" => today,
      "due_on" => Date.add(today, template.due_in_days || 0),
      "notes" => joined_notes(template)
    }
  end

  defp joined_notes(%__MODULE__{notes: nil, payment_instructions: nil}), do: nil
  defp joined_notes(%__MODULE__{notes: notes, payment_instructions: nil}), do: notes
  defp joined_notes(%__MODULE__{notes: nil, payment_instructions: how}), do: how

  defp joined_notes(%__MODULE__{notes: notes, payment_instructions: how}),
    do: notes <> "\n\n" <> how
end
