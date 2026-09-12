defmodule AperDesk.Repo.Migrations.CreateInvoiceTemplates do
  use Ecto.Migration

  @moduledoc """
  The fourth kind of template, alongside email, contract and questionnaire.

  A table rather than a set of defaults on the studio, for two reasons. A
  studio does not have one set of invoice terms — a wedding deposit, a balance
  due a fortnight before, and commercial work on thirty days are three
  different documents, and collapsing them into one default means retyping two
  of them every time. And its three siblings are already tables scoped by
  shoot type; making this one the odd shape would mean the Templates screen had
  a tab that behaved differently from the other three for no reason a user
  could see.

  A studio that only wants one just marks it the default and never picks again.

  Tax is stored in basis points rather than as an amount, because the amount
  depends on the invoice and the rate does not.
  """

  def change do
    create table(:invoice_templates, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :shoot_type, :string
      add :kind, :string, null: false, default: "balance"

      add :due_in_days, :integer, null: false, default: 14
      add :tax_bps, :integer, null: false, default: 0
      add :tax_label, :string
      add :deposit_percent, :integer

      add :notes, :text
      add :payment_instructions, :text
      add :is_default, :boolean, null: false, default: false
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:invoice_templates, [:studio_id])

    # One default per studio, enforced here rather than by the application:
    # two rows both claiming to be the default is a coin toss at the moment an
    # invoice is raised, and nobody would know which one had won.
    create unique_index(:invoice_templates, [:studio_id],
             where: "is_default AND archived_at IS NULL",
             name: :invoice_templates_one_default_per_studio
           )

    create constraint(:invoice_templates, :invoice_templates_kind,
             check: "kind IN ('deposit','balance','full','extra','credit_note')"
           )

    create constraint(:invoice_templates, :invoice_templates_tax,
             check: "tax_bps >= 0 AND tax_bps <= 10000"
           )

    create constraint(:invoice_templates, :invoice_templates_due, check: "due_in_days >= 0")
  end
end
