defmodule AperDesk.Repo.Migrations.CreateComms do
  use Ecto.Migration

  @moduledoc """
  Email: connected inboxes, threads, messages, templates and the inbound
  capture pipeline that turns a forwarded inquiry into a lead.

  Inbound capture is modelled as an explicit, inspectable pipeline
  (`received -> parsed -> matched -> drafted -> applied`) rather than a worker
  that silently does five things. When a lead is created from a bad parse, you
  can see exactly which stage was wrong and re-run from there.
  """

  def change do
    create table(:email_accounts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :nilify_all)

      add :address, :citext, null: false
      add :provider, :string, null: false, default: "imap"
      add :display_name, :string

      # Credentials are encrypted at rest with Cloak, not merely "in the
      # database". A read-only replica leak must not yield working mailbox
      # passwords or refresh tokens.
      add :imap_host, :string
      add :imap_port, :integer
      add :imap_username, :string
      add :imap_password_encrypted, :binary
      add :smtp_host, :string
      add :smtp_port, :integer
      add :smtp_username, :string
      add :smtp_password_encrypted, :binary
      add :oauth_refresh_token_encrypted, :binary
      add :oauth_expires_at, :utc_datetime_usec

      add :sync_state, :string, null: false, default: "idle"
      add :last_synced_at, :utc_datetime_usec
      add :last_uid, :integer
      add :last_error, :string
      add :capture_enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_accounts, [:studio_id, :address])

    create table(:email_threads, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :lead_id, references(:leads, type: :uuid, on_delete: :nilify_all)
      add :contact_id, references(:contacts, type: :uuid, on_delete: :nilify_all)
      add :subject, :string
      add :provider_thread_id, :string
      add :message_count, :integer, null: false, default: 0
      add :last_message_at, :utc_datetime_usec
      add :unread_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:email_threads, [:studio_id, :last_message_at])
    create index(:email_threads, [:lead_id])

    create table(:email_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :thread_id, references(:email_threads, type: :uuid, on_delete: :delete_all)
      add :account_id, references(:email_accounts, type: :uuid, on_delete: :nilify_all)
      add :lead_id, references(:leads, type: :uuid, on_delete: :nilify_all)

      add :direction, :string, null: false
      add :message_id, :string
      add :in_reply_to, :string
      add :from_address, :citext
      add :from_name, :string
      add :to_addresses, {:array, :string}, null: false, default: []
      add :cc_addresses, {:array, :string}, null: false, default: []
      add :subject, :string
      add :body_text, :text
      add :body_html, :text
      add :has_attachments, :boolean, null: false, default: false

      add :state, :string, null: false, default: "received"
      add :sent_at, :utc_datetime_usec
      add :received_at, :utc_datetime_usec
      add :read_at, :utc_datetime_usec
      add :failed_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:email_messages, [:studio_id, :received_at])
    create index(:email_messages, [:thread_id])
    create index(:email_messages, [:lead_id])

    create unique_index(:email_messages, [:account_id, :message_id],
             where: "message_id IS NOT NULL"
           )

    create constraint(:email_messages, :email_messages_direction_is_known,
             check: "direction IN ('inbound','outbound')"
           )

    create table(:email_templates, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :name, :string, null: false
      add :subject, :string, null: false
      add :body, :text, null: false
      add :shoot_type, :string
      add :system_template, :boolean, null: false, default: false
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_templates, [:studio_id, :key])

    # One row per inbound message that might be a lead, carrying the full audit
    # trail of how it was interpreted.
    create table(:inbound_captures, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :message_id, references(:email_messages, type: :uuid, on_delete: :delete_all)
      add :lead_id, references(:leads, type: :uuid, on_delete: :nilify_all)

      add :stage, :string, null: false, default: "received"
      add :raw_source, :text
      add :parsed, :map, null: false, default: %{}
      add :parser_version, :string
      add :confidence, :decimal

      add :draft_subject, :string
      add :draft_body, :text
      add :draft_model, :string
      add :draft_generated_at, :utc_datetime_usec

      # Nothing is ever sent on the studio's behalf without this being set.
      add :approved_by_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :approved_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec
      add :error, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:inbound_captures, [:studio_id, :stage])
    create index(:inbound_captures, [:lead_id])

    create constraint(:inbound_captures, :inbound_captures_stage_is_known,
             check:
               "stage IN ('received','parsed','matched','drafted','applied','rejected','failed')"
           )

    create table(:lead_capture_forms, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :citext, null: false
      add :headline, :string
      add :intro, :text
      add :success_message, :text
      add :fields, :map, null: false, default: %{}
      add :notify_emails, {:array, :string}, null: false, default: []
      add :assign_to_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :redirect_url, :string
      add :active, :boolean, null: false, default: true
      add :submission_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lead_capture_forms, [:studio_id, :slug])

    create table(:form_submissions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")

      add :form_id, references(:lead_capture_forms, type: :uuid, on_delete: :delete_all),
        null: false

      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :lead_id, references(:leads, type: :uuid, on_delete: :nilify_all)
      add :answers, :map, null: false, default: %{}
      add :ip_address, :string
      add :user_agent, :string
      add :referrer, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:form_submissions, [:form_id])
    create index(:form_submissions, [:studio_id])

    create table(:notifications, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :title, :string, null: false
      add :body, :string
      add :path, :string
      add :severity, :string, null: false, default: "info"
      add :read_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:notifications, [:user_id, :read_at])
    create index(:notifications, [:studio_id, :inserted_at])
  end
end
