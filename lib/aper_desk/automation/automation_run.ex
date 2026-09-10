defmodule AperDesk.Automation.AutomationRun do
  @moduledoc """
  One workflow firing for one event.

  The `(workflow_id, event_id)` unique index is what makes the drain idempotent:
  a re-run after a crash tries to insert the same pair and is rejected, so a
  client cannot receive the same automated email twice because a worker
  restarted.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Automation.{AutomationRunStep, OutboxEvent, Workflow}

  @statuses ~w(pending running awaiting_approval completed skipped failed cancelled)
  @terminal_statuses ~w(completed skipped failed cancelled)

  schema "automation_runs" do
    belongs_to :studio, Studio
    belongs_to :workflow, Workflow
    belongs_to :event, OutboxEvent

    field :subject_type, :string
    field :subject_id, :binary_id
    field :status, :string, default: "pending"
    field :reason, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    has_many :steps, AutomationRunStep, foreign_key: :run_id

    timestamps()
  end

  def statuses, do: @statuses
  def terminal_statuses, do: @terminal_statuses

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :studio_id,
      :workflow_id,
      :event_id,
      :subject_type,
      :subject_id,
      :status,
      :reason
    ])
    |> validate_required([:studio_id, :workflow_id, :subject_type, :subject_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:workflow_id, :event_id],
      message: "this workflow has already run for this event"
    )
    |> foreign_key_constraint(:workflow_id)
  end

  def started_changeset(run, at \\ DateTime.utc_now()),
    do: change(run, status: "running", started_at: run.started_at || at)

  def awaiting_approval_changeset(run), do: change(run, status: "awaiting_approval")

  def completed_changeset(run, at \\ DateTime.utc_now()),
    do: change(run, status: "completed", finished_at: at)

  @doc "Skip with a stated reason — an unexplained skip is impossible to debug later."
  def skipped_changeset(run, reason, at \\ DateTime.utc_now()),
    do: change(run, status: "skipped", reason: reason, finished_at: at)

  def failed_changeset(run, reason, at \\ DateTime.utc_now()),
    do: change(run, status: "failed", reason: reason, finished_at: at)

  def cancelled_changeset(run, reason, at \\ DateTime.utc_now()),
    do: change(run, status: "cancelled", reason: reason, finished_at: at)

  def finished?(%__MODULE__{status: status}), do: status in @terminal_statuses

  @doc "How long the run took, in milliseconds, or nil while still in flight."
  def duration_ms(%__MODULE__{started_at: %DateTime{} = from, finished_at: %DateTime{} = to}),
    do: DateTime.diff(to, from, :millisecond)

  def duration_ms(%__MODULE__{}), do: nil
end
