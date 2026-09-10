defmodule AperDesk.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  @moduledoc """
  Identity and tenancy.

  The important departure from the system this replaces: a user is no longer
  pinned to one studio by a `users.studio_id` column. Membership is its own
  table, so a freelance second shooter can hold a seat in three studios with a
  different role in each, and an agency can invite someone who already has an
  account without cloning their identity.
  """

  def change do
    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :email, :citext, null: false
      add :hashed_password, :string
      add :name, :string, null: false
      add :avatar_url, :string
      add :phone, :string
      add :locale, :string, null: false, default: "en"
      add :time_zone, :string, null: false, default: "Etc/UTC"
      add :confirmed_at, :utc_datetime_usec
      add :platform_admin, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])

    create table(:studios, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :name, :string, null: false
      add :slug, :citext, null: false
      add :tagline, :string
      add :about, :text
      add :website, :string
      add :support_email, :string
      add :phone, :string

      # Branding applied to every client-facing surface: quotes, contracts,
      # galleries, portal, outbound email.
      add :logo_url, :string
      add :brand_color, :string, null: false, default: "#B8722E"

      add :base_currency, :string, null: false, default: "USD"
      add :time_zone, :string, null: false, default: "Etc/UTC"
      add :country_code, :string
      add :city, :string

      # Reply-time promise the dashboard measures against.
      add :reply_sla_minutes, :integer, null: false, default: 240

      add :listed_in_directory, :boolean, null: false, default: false
      add :featured_until, :utc_datetime_usec

      add :onboarding_state, :string, null: false, default: "new"
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:studios, [:slug])
    create constraint(:studios, :studios_currency_is_iso, check: "assert_currency(base_currency)")

    # Roles are the five seats the product sells: owner, photographer, finance,
    # hr, ops. Kept as a check constraint rather than a Postgres enum so adding
    # one later is a migration, not a type rewrite that locks the table.
    create table(:memberships, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :title, :string
      add :employment_type, :string, null: false, default: "staff"
      add :day_rate_cents, :bigint
      add :day_rate_currency, :string
      add :contract_ends_on, :date
      add :status, :string, null: false, default: "active"
      add :last_active_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memberships, [:user_id, :studio_id])
    create index(:memberships, [:studio_id, :role])

    create constraint(:memberships, :memberships_role_is_known,
             check: "role IN ('owner','photographer','finance','hr','ops')"
           )

    create constraint(:memberships, :memberships_employment_type_is_known,
             check: "employment_type IN ('staff','freelance')"
           )

    create constraint(:memberships, :memberships_status_is_known,
             check: "status IN ('invited','active','suspended','left')"
           )

    create table(:user_invitations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :invited_by_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :email, :citext, null: false
      add :role, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_invitations, [:token_hash])
    create index(:user_invitations, [:studio_id, :email])

    # Session, password-reset, confirmation and mobile refresh tokens all share
    # one table. Only the hash is stored, so a database leak does not hand the
    # attacker live sessions.
    create table(:user_tokens, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :device_label, :string
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:user_tokens, [:context, :token_hash])
    create index(:user_tokens, [:user_id, :context])
  end
end
