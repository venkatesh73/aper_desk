defmodule AperDesk.Repo.Migrations.CreateCrm do
  use Ecto.Migration

  @moduledoc """
  Contacts and the lead pipeline.

  A contact is a person; a lead is one piece of work that person asked about.
  Splitting them (rather than the common shortcut of one row that is both) is
  what lets a couple book a wedding in 2027 and a newborn shoot in 2029 without
  duplicating the humans or losing the history.
  """

  def change do
    create table(:contacts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :partner_name, :string
      add :email, :citext
      add :phone, :string
      add :company, :string
      add :preferred_channel, :string, null: false, default: "email"
      add :time_zone, :string
      add :locale, :string
      add :currency, :string
      add :notes, :text
      add :address, :map, null: false, default: %{}
      add :marketing_opt_in, :boolean, null: false, default: false
      add :source, :string
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:contacts, [:studio_id])
    create unique_index(:contacts, [:studio_id, :email], where: "email IS NOT NULL")

    # Trigram index so the "search clients" box stays fast on a large address
    # book without pulling in a separate search service.
    execute "CREATE INDEX contacts_name_trgm ON contacts USING gin (name gin_trgm_ops)",
            "DROP INDEX contacts_name_trgm"

    create table(:leads, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :contact_id, references(:contacts, type: :uuid, on_delete: :nilify_all)
      add :owner_id, references(:users, type: :uuid, on_delete: :nilify_all)

      add :reference, :string, null: false
      add :title, :string, null: false
      add :shoot_type, :string, null: false, default: "other"
      add :stage, :string, null: false, default: "new"

      # The date the client asked about, before it becomes a real booking. Kept
      # nullable because plenty of inquiries arrive without one.
      add :desired_date, :date
      add :desired_end_date, :date
      add :flexible_dates, :boolean, null: false, default: false
      add :location, :string
      add :city, :string
      add :country_code, :string
      add :guest_count, :integer

      add :budget_cents, :bigint
      add :budget_currency, :string
      add :estimated_value_cents, :bigint
      add :estimated_value_currency, :string

      add :source, :string, null: false, default: "manual"
      add :source_detail, :string

      # Reply-time SLA lives on the row so "who has not been answered" is an
      # index scan, not a per-request join over the email log.
      add :first_response_due_at, :utc_datetime_usec
      add :first_responded_at, :utc_datetime_usec
      add :last_client_message_at, :utc_datetime_usec
      add :last_studio_message_at, :utc_datetime_usec

      add :lost_reason, :string
      add :won_at, :utc_datetime_usec
      add :lost_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec

      add :custom_fields, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:leads, [:studio_id, :reference])
    create index(:leads, [:studio_id, :stage])
    create index(:leads, [:studio_id, :owner_id, :stage])
    create index(:leads, [:studio_id, :desired_date])
    create index(:leads, [:contact_id])

    # Partial index for the dashboard's single most-run query: leads whose reply
    # window has passed and that nobody has answered.
    create index(:leads, [:studio_id, :first_response_due_at],
             where: "first_responded_at IS NULL AND archived_at IS NULL",
             name: :leads_awaiting_first_reply
           )

    create constraint(:leads, :leads_stage_is_known,
             check:
               "stage IN ('new','contacted','consult','quote_sent','booked','completed','lost')"
           )

    create table(:tags, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :name, :citext, null: false
      add :color, :string
      add :kind, :string, null: false, default: "general"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tags, [:studio_id, :name])

    create table(:taggings, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :tag_id, references(:tags, type: :uuid, on_delete: :delete_all), null: false
      add :taggable_type, :string, null: false
      add :taggable_id, :uuid, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:taggings, [:tag_id, :taggable_type, :taggable_id])
    create index(:taggings, [:taggable_type, :taggable_id])

    # Per-studio custom fields. The values live in `leads.custom_fields` as
    # JSONB; this table is the schema that renders and validates them.
    create table(:custom_field_definitions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :entity, :string, null: false, default: "lead"
      add :key, :string, null: false
      add :label, :string, null: false
      add :field_type, :string, null: false, default: "text"
      add :options, {:array, :string}, null: false, default: []
      add :required, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:custom_field_definitions, [:studio_id, :entity, :key])
  end
end
