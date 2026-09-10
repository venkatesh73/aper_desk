defmodule AperDesk.Repo.Migrations.CreateFinance do
  use Ecto.Migration

  @moduledoc """
  Invoices, payments, crew payouts and expenses.

  Money is integer minor units plus an ISO code, everywhere, with no exceptions.
  Every document also stores the FX rate to the studio's base currency at the
  moment it was issued, so the multi-currency reports the Agency plan sells are
  reproducible rather than recalculated against today's rate.
  """

  def change do
    create table(:invoices, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :contact_id, references(:contacts, type: :uuid, on_delete: :nilify_all)
      add :lead_id, references(:leads, type: :uuid, on_delete: :nilify_all)
      add :job_id, references(:jobs, type: :uuid, on_delete: :nilify_all)
      add :quote_id, references(:quotes, type: :uuid, on_delete: :nilify_all)

      add :reference, :string, null: false
      add :kind, :string, null: false, default: "balance"
      add :status, :string, null: false, default: "draft"

      add :currency, :string, null: false, default: "USD"
      add :fx_rate_to_base, :decimal, null: false, default: 1.0
      add :subtotal_cents, :bigint, null: false, default: 0
      add :discount_cents, :bigint, null: false, default: 0
      add :tax_cents, :bigint, null: false, default: 0
      add :total_cents, :bigint, null: false, default: 0
      add :paid_cents, :bigint, null: false, default: 0

      add :issued_on, :date
      add :due_on, :date
      add :notes, :text
      add :purchase_order, :string

      add :share_token_hash, :binary
      add :sent_at, :utc_datetime_usec
      add :paid_at, :utc_datetime_usec
      add :voided_at, :utc_datetime_usec
      add :written_off_at, :utc_datetime_usec
      add :reminders_sent, :integer, null: false, default: 0
      add :last_reminder_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invoices, [:studio_id, :reference])
    create unique_index(:invoices, [:share_token_hash], where: "share_token_hash IS NOT NULL")
    create index(:invoices, [:studio_id, :status, :due_on])
    create index(:invoices, [:job_id])

    create index(:invoices, [:studio_id, :due_on],
             where: "status IN ('sent','partial') AND voided_at IS NULL",
             name: :invoices_outstanding
           )

    create constraint(:invoices, :invoices_currency_is_iso, check: "assert_currency(currency)")

    create constraint(:invoices, :invoices_kind_is_known,
             check: "kind IN ('deposit','balance','full','extra','credit_note')"
           )

    create constraint(:invoices, :invoices_status_is_known,
             check: "status IN ('draft','sent','partial','paid','overdue','void','written_off')"
           )

    create constraint(:invoices, :invoices_paid_not_negative, check: "paid_cents >= 0")

    create table(:invoice_line_items, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :invoice_id, references(:invoices, type: :uuid, on_delete: :delete_all), null: false
      add :description, :string, null: false
      add :quantity, :decimal, null: false, default: 1
      add :unit_price_cents, :bigint, null: false, default: 0
      add :total_cents, :bigint, null: false, default: 0
      add :tax_rate_bps, :integer, null: false, default: 0
      add :position, :integer, null: false, default: 0
    end

    create index(:invoice_line_items, [:invoice_id])

    create table(:payments, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :invoice_id, references(:invoices, type: :uuid, on_delete: :nilify_all)
      add :amount_cents, :bigint, null: false
      add :currency, :string, null: false
      add :fx_rate_to_base, :decimal, null: false, default: 1.0
      add :method, :string, null: false, default: "card"
      add :status, :string, null: false, default: "succeeded"
      add :provider, :string
      add :provider_reference, :string
      add :received_at, :utc_datetime_usec, null: false
      add :fee_cents, :bigint, null: false, default: 0
      add :refunded_cents, :bigint, null: false, default: 0
      add :note, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:payments, [:studio_id, :received_at])
    create index(:payments, [:invoice_id])

    create unique_index(:payments, [:provider, :provider_reference],
             where: "provider_reference IS NOT NULL"
           )

    # Paying the crew from the same record as the shoot they worked. The system
    # being replaced had no concept of this at all — second shooters were
    # tracked in a spreadsheet.
    create table(:payouts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :job_id, references(:jobs, type: :uuid, on_delete: :nilify_all)
      add :assignment_id, references(:assignments, type: :uuid, on_delete: :nilify_all)
      add :reference, :string, null: false
      add :description, :string
      add :amount_cents, :bigint, null: false
      add :currency, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :approved_by_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :approved_at, :utc_datetime_usec
      add :paid_at, :utc_datetime_usec
      add :run_id, :uuid

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:payouts, [:studio_id, :reference])
    create index(:payouts, [:studio_id, :status])
    create index(:payouts, [:run_id])

    create constraint(:payouts, :payouts_status_is_known,
             check: "status IN ('pending','approved','paid','cancelled')"
           )

    create table(:expenses, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :job_id, references(:jobs, type: :uuid, on_delete: :nilify_all)
      add :user_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :category, :string, null: false, default: "other"
      add :description, :string, null: false
      add :amount_cents, :bigint, null: false
      add :currency, :string, null: false
      add :fx_rate_to_base, :decimal, null: false, default: 1.0
      add :incurred_on, :date, null: false
      add :billable, :boolean, null: false, default: false
      add :receipt_url, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:expenses, [:studio_id, :incurred_on])
    create index(:expenses, [:job_id])

    # Daily FX snapshots. Documents reference the rate they were issued at, and
    # this table is where that rate came from.
    create table(:fx_rates, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :base_currency, :string, null: false
      add :quote_currency, :string, null: false
      add :rate, :decimal, null: false
      add :as_of, :date, null: false
      add :source, :string, null: false, default: "manual"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:fx_rates, [:base_currency, :quote_currency, :as_of])
  end
end
