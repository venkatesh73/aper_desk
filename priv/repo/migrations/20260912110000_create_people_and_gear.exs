defmodule AperDesk.Repo.Migrations.CreatePeopleAndGear do
  use Ecto.Migration

  @moduledoc """
  The tables HR and Ops actually work out of.

  Both roles existed in the permission table and had no features of their own —
  HR got the team roster and nothing about leave or onboarding, Ops got the
  calendar and nothing about the kit that has to be in the car.

  Leave is deliberately *not* modelled as an assignment. An assignment is a
  commitment to a studio job and carries a payout, a role and a period that
  clashes against other commitments. Leave is the absence of availability. It
  shares the clash question, and `assignments` already answers that with its
  exclusion constraint — so an approved leave request writes a `hold`-kind
  assignment alongside itself, which is what makes booking somebody who is on
  holiday impossible rather than merely discouraged.
  """

  def change do
    create table(:leave_requests, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :decided_by_id, references(:users, type: :uuid, on_delete: :nilify_all)

      # The assignment that blocks the calendar once this is approved. Nilify
      # rather than cascade: releasing the block must not delete the record of
      # the leave having been taken.
      add :assignment_id, references(:assignments, type: :uuid, on_delete: :nilify_all)

      add :kind, :string, null: false, default: "holiday"
      add :starts_on, :date, null: false
      add :ends_on, :date, null: false
      add :reason, :text
      add :status, :string, null: false, default: "pending"
      add :decided_at, :utc_datetime_usec
      add :decision_note, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:leave_requests, [:studio_id, :status])
    create index(:leave_requests, [:user_id])

    create constraint(:leave_requests, :leave_requests_kind,
             check: "kind IN ('holiday','sick','unpaid','parental','other')"
           )

    create constraint(:leave_requests, :leave_requests_status,
             check: "status IN ('pending','approved','declined','cancelled')"
           )

    # A request that ends before it starts is not a date range anyone can act
    # on, and it would produce an empty assignment period on approval.
    create constraint(:leave_requests, :leave_requests_dates, check: "ends_on >= starts_on")

    create table(:onboarding_tasks, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false

      add :membership_id, references(:memberships, type: :uuid, on_delete: :delete_all),
        null: false

      add :label, :string, null: false
      add :detail, :text
      add :position, :integer, null: false, default: 0
      add :done_at, :utc_datetime_usec
      add :done_by_id, references(:users, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:onboarding_tasks, [:membership_id])
    create index(:onboarding_tasks, [:studio_id])

    create table(:gear_items, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :category, :string, null: false, default: "other"
      add :serial, :string
      add :notes, :text
      add :retired_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gear_items, [:studio_id])

    create constraint(:gear_items, :gear_items_category,
             check:
               "category IN ('body','lens','lighting','audio','support','storage','transport','other')"
           )

    create table(:gear_checkouts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :gear_item_id, references(:gear_items, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :job_id, references(:jobs, type: :uuid, on_delete: :nilify_all)

      add :taken_at, :utc_datetime_usec, null: false
      add :due_back_on, :date
      add :returned_at, :utc_datetime_usec
      add :condition_note, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gear_checkouts, [:studio_id])
    create index(:gear_checkouts, [:gear_item_id])

    # One piece of kit is in one pair of hands at a time. Enforced here rather
    # than by a status column on `gear_items`, because a column would need the
    # application to keep it in step and two people checking out the same body
    # at once is exactly the race a partial unique index rules out.
    create unique_index(:gear_checkouts, [:gear_item_id],
             where: "returned_at IS NULL",
             name: :gear_checkouts_one_open_per_item
           )
  end
end
