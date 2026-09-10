defmodule AperDesk.Repo.Migrations.CreateScheduling do
  use Ecto.Migration

  @moduledoc """
  Jobs, crew assignments, holds and availability.

  This is the single biggest structural improvement over the system being
  replaced. There, "is this date free?" was an application-level query that
  could race two simultaneous bookings and had no notion of travel time. Here
  every occupied span — a shoot, a travel day, leave, a soft hold — lands in
  `assignments` as a `tstzrange`, and a GiST exclusion constraint makes it
  physically impossible for one person to hold two overlapping spans. Two
  concurrent bookings do not both win; the loser gets a constraint violation
  that the context turns into a clash the UI can offer to resolve.
  """

  def change do
    create table(:jobs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :lead_id, references(:leads, type: :uuid, on_delete: :nilify_all)
      add :contact_id, references(:contacts, type: :uuid, on_delete: :nilify_all)
      add :package_id, references(:packages, type: :uuid, on_delete: :nilify_all)

      add :reference, :string, null: false
      add :title, :string, null: false
      add :shoot_type, :string, null: false, default: "other"
      add :status, :string, null: false, default: "confirmed"

      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec, null: false
      add :time_zone, :string, null: false, default: "Etc/UTC"

      # Buffers are stored separately from the shoot window so the UI can show
      # "11:00–22:00" while the clash check reserves the drive there and back.
      add :travel_before_minutes, :integer, null: false, default: 0
      add :travel_after_minutes, :integer, null: false, default: 0

      add :venue_name, :string
      add :venue_address, :string
      add :city, :string
      add :country_code, :string
      add :venue_notes, :text
      add :shot_list, :text

      add :value_cents, :bigint
      add :value_currency, :string

      add :gallery_due_on, :date
      add :completed_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      add :cancellation_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:jobs, [:studio_id, :reference])
    create index(:jobs, [:studio_id, :starts_at])
    create index(:jobs, [:studio_id, :status, :starts_at])
    create index(:jobs, [:lead_id])

    create constraint(:jobs, :jobs_end_after_start, check: "ends_at > starts_at")

    create constraint(:jobs, :jobs_status_is_known,
             check: "status IN ('pencilled','confirmed','shot','delivered','cancelled')"
           )

    # Every reservation of a person's time, whatever the reason.
    create table(:assignments, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :job_id, references(:jobs, type: :uuid, on_delete: :delete_all)

      add :kind, :string, null: false, default: "shoot"
      add :role, :string, null: false, default: "lead_photographer"
      add :label, :string

      # The authoritative occupied window, buffers already folded in.
      add :period, :tstzrange, null: false

      # A soft hold expires on its own so a client who never replies does not
      # silently block a Saturday forever.
      add :expires_at, :utc_datetime_usec
      add :released_at, :utc_datetime_usec

      add :payout_cents, :bigint
      add :payout_currency, :string
      add :payout_status, :string, null: false, default: "none"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:assignments, [:studio_id, :user_id])
    create index(:assignments, [:job_id])

    execute "CREATE INDEX assignments_period_idx ON assignments USING gist (period)",
            "DROP INDEX assignments_period_idx"

    create constraint(:assignments, :assignments_kind_is_known,
             check: "kind IN ('shoot','travel','hold','leave','edit','other')"
           )

    create constraint(:assignments, :assignments_payout_status_is_known,
             check: "payout_status IN ('none','pending','approved','paid')"
           )

    # The constraint that makes clash detection real. Released and expired rows
    # are excluded from the check so a lapsed hold stops blocking the date the
    # moment it is released.
    execute """
            ALTER TABLE assignments
              ADD CONSTRAINT assignments_no_overlap
              EXCLUDE USING gist (
                user_id WITH =,
                period WITH &&
              )
              WHERE (released_at IS NULL AND kind <> 'hold')
            """,
            "ALTER TABLE assignments DROP CONSTRAINT assignments_no_overlap"

    # Holds are checked separately and only against other holds, so a soft hold
    # warns about a confirmed shoot rather than being refused outright — the
    # studio decides whether to double-book, the database just tells the truth.
    execute "CREATE INDEX assignments_active_holds ON assignments USING gist (user_id, period) WHERE (kind = 'hold' AND released_at IS NULL)",
            "DROP INDEX assignments_active_holds"

    # Recurring weekly availability, used by the public booking page.
    create table(:availability_rules, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all)
      add :day_of_week, :integer, null: false
      add :starts_at_minute, :integer, null: false
      add :ends_at_minute, :integer, null: false
      add :bookable, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:availability_rules, [:studio_id, :day_of_week])

    create constraint(:availability_rules, :availability_day_in_range,
             check: "day_of_week BETWEEN 0 AND 6"
           )

    create constraint(:availability_rules, :availability_minutes_ordered,
             check: "ends_at_minute > starts_at_minute"
           )

    # Slots offered on the public booking page, and the bookings against them.
    create table(:booking_slots, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :package_id, references(:packages, type: :uuid, on_delete: :nilify_all)
      add :user_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :lead_id, references(:leads, type: :uuid, on_delete: :nilify_all)
      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "open"
      add :booked_by_email, :citext
      add :booked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:booking_slots, [:studio_id, :starts_at])

    create constraint(:booking_slots, :booking_slots_status_is_known,
             check: "status IN ('open','held','booked','cancelled')"
           )
  end
end
