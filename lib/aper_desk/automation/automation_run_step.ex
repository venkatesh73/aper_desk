defmodule AperDesk.Automation.AutomationRunStep do
  @moduledoc """
  The execution record for one step of one run.

  `awaiting_approval` is a status rather than a boolean flag, which is what
  makes "what is waiting on me?" a single indexed query across every workflow
  in the studio instead of a scan joined against workflow settings.

  `preview` holds what the step *would* do — the rendered subject and body, the
  stage it would move a lead to. It is written before approval, so the person
  approving sees the actual message rather than a description of one.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.User
  alias AperDesk.Automation.{AutomationRun, WorkflowStep}

  @statuses ~w(pending awaiting_approval approved running completed skipped failed rejected)
  @actionable_statuses ~w(pending awaiting_approval)

  schema "automation_run_steps" do
    belongs_to :run, AutomationRun
    belongs_to :workflow_step, WorkflowStep
    belongs_to :approved_by, User

    field :name, :string
    field :action, :string
    field :status, :string, default: "pending"
    field :scheduled_for, :utc_datetime_usec
    field :preview, :map, default: %{}
    field :result, :map, default: %{}
    field :approved_at, :utc_datetime_usec
    field :executed_at, :utc_datetime_usec
    field :error, :string
    field :position, :integer, default: 0

    timestamps()
  end

  def statuses, do: @statuses
  def actionable_statuses, do: @actionable_statuses

  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :run_id,
      :workflow_step_id,
      :name,
      :action,
      :status,
      :scheduled_for,
      :preview,
      :position
    ])
    |> validate_required([:run_id, :name, :action])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:run_id)
  end

  @doc "Store the rendered preview and park the step for a human."
  def awaiting_approval_changeset(step, preview) when is_map(preview),
    do: change(step, status: "awaiting_approval", preview: preview)

  def approved_changeset(step, %User{id: user_id}, at \\ DateTime.utc_now()),
    do: change(step, status: "approved", approved_by_id: user_id, approved_at: at)

  def rejected_changeset(step, %User{id: user_id}, at \\ DateTime.utc_now()),
    do: change(step, status: "rejected", approved_by_id: user_id, approved_at: at)

  def completed_changeset(step, result \\ %{}, at \\ DateTime.utc_now()),
    do: change(step, status: "completed", result: result, executed_at: at, error: nil)

  def failed_changeset(step, error, at \\ DateTime.utc_now()),
    do: change(step, status: "failed", error: error, executed_at: at)

  def skipped_changeset(step), do: change(step, status: "skipped")

  @doc "Whether the step is due to run now."
  def due?(%__MODULE__{status: status}, _now) when status not in @actionable_statuses, do: false
  def due?(%__MODULE__{scheduled_for: nil}, _now), do: true

  def due?(%__MODULE__{scheduled_for: scheduled_for}, now),
    do: DateTime.compare(now, scheduled_for) != :lt

  @doc "Whether this step is blocking the run on a human."
  def blocking?(%__MODULE__{status: "awaiting_approval"}), do: true
  def blocking?(%__MODULE__{}), do: false
end
