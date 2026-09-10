defmodule AperDesk.Repo.Migrations.CreateAutomation do
  use Ecto.Migration

  @moduledoc """
  Workflows, nurture sequences and the event outbox that drives them.

  The design promise on the landing page — "automations should be obvious, not
  magic" — is a schema decision, not a UI one. Domain changes append to
  `outbox_events` in the *same transaction* that changed the data. A single
  drain job turns events into `automation_runs`. That gives three properties
  the previous design could not offer: nothing is lost if a worker dies between
  the write and the enqueue, every fire is explainable ("this ran because event
  X matched rule Y"), and a rule can be replayed against history to preview
  what it would have done before you switch it on.
  """

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :string
      add :shoot_type, :string
      add :trigger_event, :string, null: false
      add :trigger_conditions, :map, null: false, default: %{}
      add :active, :boolean, null: false, default: false

      # Per-workflow default that individual steps can override. "ask" is the
      # default because a studio's reputation is on the line in every message.
      add :approval_mode, :string, null: false, default: "ask"
      add :run_count, :integer, null: false, default: 0
      add :last_run_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflows, [:studio_id, :trigger_event, :active])

    create constraint(:workflows, :workflows_approval_mode_is_known,
             check: "approval_mode IN ('auto','ask')"
           )

    create table(:workflow_steps, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :workflow_id, references(:workflows, type: :uuid, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :action, :string, null: false
      add :config, :map, null: false, default: %{}
      add :delay_minutes, :integer, null: false, default: 0
      add :approval_mode, :string
      add :position, :integer, null: false, default: 0
      add :active, :boolean, null: false, default: true
    end

    create index(:workflow_steps, [:workflow_id, :position])

    create table(:nurture_sequences, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :shoot_type, :string
      add :enter_when_stage, :string
      add :enter_after_days, :integer, null: false, default: 3
      add :exit_on_reply, :boolean, null: false, default: true
      add :active, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:nurture_sequences, [:studio_id, :active])

    create table(:nurture_steps, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")

      add :sequence_id, references(:nurture_sequences, type: :uuid, on_delete: :delete_all),
        null: false

      add :template_id, references(:email_templates, type: :uuid, on_delete: :nilify_all)
      add :day_offset, :integer, null: false
      add :subject, :string
      add :body, :text
      add :position, :integer, null: false, default: 0
    end

    create index(:nurture_steps, [:sequence_id, :position])

    # The transactional outbox. Written in the same transaction as the domain
    # change it describes, drained separately.
    create table(:outbox_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :subject_type, :string, null: false
      add :subject_id, :uuid, null: false
      add :actor_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false
      add :processed_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      add :last_error, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:outbox_events, [:studio_id, :name, :occurred_at])
    create index(:outbox_events, [:subject_type, :subject_id])

    create index(:outbox_events, [:occurred_at],
             where: "processed_at IS NULL",
             name: :outbox_events_unprocessed
           )

    # One row per (event, workflow) pair. The unique index is what makes the
    # drain idempotent: re-running it can never fire a workflow twice.
    create table(:automation_runs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :workflow_id, references(:workflows, type: :uuid, on_delete: :delete_all), null: false
      add :event_id, references(:outbox_events, type: :uuid, on_delete: :nilify_all)
      add :subject_type, :string, null: false
      add :subject_id, :uuid, null: false
      add :status, :string, null: false, default: "pending"
      add :reason, :string
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:automation_runs, [:workflow_id, :event_id],
             where: "event_id IS NOT NULL"
           )

    create index(:automation_runs, [:studio_id, :status])

    create constraint(:automation_runs, :automation_runs_status_is_known,
             check:
               "status IN ('pending','running','awaiting_approval','completed','skipped','failed','cancelled')"
           )

    # Per-step execution record. `awaiting_approval` is a first-class state, not
    # a flag, so "what is waiting on me?" is a query.
    create table(:automation_run_steps, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :run_id, references(:automation_runs, type: :uuid, on_delete: :delete_all), null: false
      add :workflow_step_id, references(:workflow_steps, type: :uuid, on_delete: :nilify_all)
      add :name, :string, null: false
      add :action, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :scheduled_for, :utc_datetime_usec
      add :preview, :map, null: false, default: %{}
      add :result, :map, null: false, default: %{}
      add :approved_by_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :approved_at, :utc_datetime_usec
      add :executed_at, :utc_datetime_usec
      add :error, :string
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:automation_run_steps, [:run_id, :position])

    create index(:automation_run_steps, [:status, :scheduled_for],
             where: "status IN ('pending','awaiting_approval')",
             name: :automation_run_steps_actionable
           )

    # Human-readable history. Separate from outbox_events, which is machinery:
    # this is what renders in the activity log a photographer actually reads.
    create table(:activity_logs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :actor_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :actor_label, :string
      add :subject_type, :string, null: false
      add :subject_id, :uuid, null: false
      add :action, :string, null: false
      add :summary, :string, null: false
      add :reason, :string
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:activity_logs, [:studio_id, :occurred_at])
    create index(:activity_logs, [:subject_type, :subject_id, :occurred_at])
  end
end
