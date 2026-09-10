defmodule AperDesk.Repo.Migrations.CreateQuotesAndContracts do
  use Ecto.Migration

  @moduledoc """
  Quotes, contract templates, contracts and signatures.

  Documents sent to a client freeze their own copy of the numbers and the FX
  rate used. A quote the client accepted last March must still show March's
  price and March's exchange rate, whatever the package costs today.
  """

  def change do
    create table(:quotes, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :lead_id, references(:leads, type: :uuid, on_delete: :nilify_all)
      add :contact_id, references(:contacts, type: :uuid, on_delete: :nilify_all)
      add :package_id, references(:packages, type: :uuid, on_delete: :nilify_all)
      add :prepared_by_id, references(:users, type: :uuid, on_delete: :nilify_all)

      add :reference, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :title, :string, null: false

      add :currency, :string, null: false, default: "USD"
      add :fx_rate_to_base, :decimal, null: false, default: 1.0
      add :subtotal_cents, :bigint, null: false, default: 0
      add :discount_cents, :bigint, null: false, default: 0
      add :tax_cents, :bigint, null: false, default: 0
      add :total_cents, :bigint, null: false, default: 0
      add :deposit_cents, :bigint, null: false, default: 0

      add :valid_until, :date
      add :terms, :text
      add :client_note, :text

      # Public token for the client link. Hashed at rest so a leaked backup does
      # not expose every open quote.
      add :share_token_hash, :binary
      add :sent_at, :utc_datetime_usec
      add :first_viewed_at, :utc_datetime_usec
      add :view_count, :integer, null: false, default: 0
      add :accepted_at, :utc_datetime_usec
      add :declined_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:quotes, [:studio_id, :reference])
    create unique_index(:quotes, [:share_token_hash], where: "share_token_hash IS NOT NULL")
    create index(:quotes, [:studio_id, :status])
    create index(:quotes, [:lead_id])
    create constraint(:quotes, :quotes_currency_is_iso, check: "assert_currency(currency)")

    create constraint(:quotes, :quotes_status_is_known,
             check: "status IN ('draft','sent','viewed','accepted','declined','expired')"
           )

    create table(:quote_line_items, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :quote_id, references(:quotes, type: :uuid, on_delete: :delete_all), null: false
      add :description, :string, null: false
      add :detail, :string
      add :quantity, :decimal, null: false, default: 1
      add :unit_price_cents, :bigint, null: false, default: 0
      add :total_cents, :bigint, null: false, default: 0
      add :taxable, :boolean, null: false, default: true
      add :position, :integer, null: false, default: 0
    end

    create index(:quote_line_items, [:quote_id])

    create table(:contract_templates, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :shoot_type, :string
      add :body, :text, null: false
      add :requires_deposit, :boolean, null: false, default: true
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:contract_templates, [:studio_id])

    create table(:contracts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :lead_id, references(:leads, type: :uuid, on_delete: :nilify_all)
      add :job_id, references(:jobs, type: :uuid, on_delete: :nilify_all)
      add :quote_id, references(:quotes, type: :uuid, on_delete: :nilify_all)
      add :contact_id, references(:contacts, type: :uuid, on_delete: :nilify_all)
      add :template_id, references(:contract_templates, type: :uuid, on_delete: :nilify_all)

      add :reference, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :title, :string, null: false

      # The rendered body at send time. Never re-render a signed contract from
      # its template: the template may have changed since.
      add :body, :text, null: false
      add :body_checksum, :string, null: false

      add :share_token_hash, :binary
      add :sent_at, :utc_datetime_usec
      add :signed_at, :utc_datetime_usec
      add :voided_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:contracts, [:studio_id, :reference])
    create unique_index(:contracts, [:share_token_hash], where: "share_token_hash IS NOT NULL")
    create index(:contracts, [:studio_id, :status])

    create constraint(:contracts, :contracts_status_is_known,
             check: "status IN ('draft','sent','viewed','signed','declined','voided','expired')"
           )

    # Signature evidence. IP and user agent are kept because that is what makes
    # an e-signature defensible if it is ever challenged.
    create table(:signatures, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :contract_id, references(:contracts, type: :uuid, on_delete: :delete_all), null: false
      add :signer_name, :string, null: false
      add :signer_email, :citext, null: false
      add :signature_svg, :text
      add :typed_name, :string
      add :signed_at, :utc_datetime_usec, null: false
      add :ip_address, :string
      add :user_agent, :string
      add :document_checksum, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:signatures, [:contract_id])
  end
end
