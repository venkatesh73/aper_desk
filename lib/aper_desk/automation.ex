defmodule AperDesk.Automation do
  @moduledoc """
  Turning domain events into workflow runs, and running them.

  The drain is the only writer of `automation_runs`, and every insert is
  guarded by the unique index on `(workflow_id, event_id)`. That is what makes
  the whole pipeline safe to retry: a drain that dies halfway, or runs twice
  because a supervisor restarted it, cannot fire a workflow twice for the same
  event. The second attempt collides with the index and moves on.

  Steps that need a person park in `awaiting_approval` with a rendered preview
  of exactly what would be sent, because "automations should be obvious, not
  magic" is a promise about what a photographer can inspect before it goes out
  in their name.
  """

  import Ecto.Query

  alias AperDesk.Authorization

  alias AperDesk.Automation.{
    ActivityLog,
    AutomationRun,
    AutomationRunStep,
    NurtureSequence,
    OutboxEvent,
    Workflow,
    WorkflowStep
  }

  alias AperDesk.Billing.Limits
  alias AperDesk.Repo
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias Ecto.Multi

  @drain_batch 100

  ## Workflows

  def list_workflows(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"workflow.read") do
      {:ok,
       Workflow
       |> Scoped.for_studio(scope)
       |> where([w], is_nil(w.archived_at))
       |> preload(:steps)
       |> order_by([w], asc: w.name)
       |> Repo.all()}
    end
  end

  def fetch_workflow(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"workflow.read") do
      case Workflow |> Scoped.for_studio(scope) |> preload(:steps) |> Repo.get(id) do
        nil -> {:error, :not_found}
        workflow -> {:ok, workflow}
      end
    end
  end

  def create_workflow(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"workflow.write") do
      Multi.new()
      |> Multi.run(:limit, fn repo, _ ->
        case Limits.ensure_headroom(repo, scope, "workflows") do
          :ok -> {:ok, :within_limit}
          error -> error
        end
      end)
      |> Multi.insert(:workflow, Workflow.changeset(%Workflow{}, Scoped.put_studio(attrs, scope)))
      |> Repo.transaction()
      |> unwrap(:workflow)
    end
  end

  def update_workflow(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"workflow.write"),
         {:ok, workflow} <- fetch_workflow(scope, id) do
      workflow |> Workflow.changeset(attrs) |> Repo.update()
    end
  end

  ## Draining the outbox

  @doc """
  Turn unprocessed events into automation runs.

  Safe to run concurrently and safe to retry. Each event is claimed with a
  conditional UPDATE, so two drain workers cannot both process one event; the
  loser's update matches zero rows and it skips on.
  """
  def drain(limit \\ @drain_batch) do
    events =
      Repo.all(
        from e in OutboxEvent,
          where: is_nil(e.processed_at),
          order_by: [asc: e.occurred_at],
          limit: ^limit
      )

    Enum.reduce(events, %{processed: 0, runs: 0, skipped: 0}, fn event, acc ->
      case claim(event) do
        :claimed ->
          created = fan_out(event)
          %{acc | processed: acc.processed + 1, runs: acc.runs + created}

        :taken ->
          %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  # Claim by conditional update. `processed_at IS NULL` in the WHERE clause is
  # the entire concurrency control: exactly one worker can transition an event.
  defp claim(%OutboxEvent{} = event) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(e in OutboxEvent, where: e.id == ^event.id and is_nil(e.processed_at)),
        set: [processed_at: now]
      )

    if count == 1, do: :claimed, else: :taken
  end

  defp fan_out(%OutboxEvent{} = event) do
    workflows =
      Repo.all(
        from w in Workflow,
          where:
            w.studio_id == ^event.studio_id and w.trigger_event == ^event.name and w.active and
              is_nil(w.archived_at),
          preload: :steps
      )

    workflows
    |> Enum.filter(&Workflow.matches?(&1, event.payload))
    |> Enum.count(&(create_run(&1, event) == :ok))
  end

  @doc """
  Create a run for one workflow and event.

  The unique index on `(workflow_id, event_id)` is the idempotency guarantee:
  a replay inserts nothing and returns `:already_run`.
  """
  def create_run(%Workflow{} = workflow, %OutboxEvent{} = event) do
    now = DateTime.utc_now()

    steps =
      workflow.steps
      |> Enum.filter(& &1.active)
      |> Enum.sort_by(& &1.position)

    Multi.new()
    |> Multi.insert(
      :run,
      AutomationRun.changeset(%AutomationRun{}, %{
        studio_id: workflow.studio_id,
        workflow_id: workflow.id,
        event_id: event.id,
        subject_type: event.subject_type,
        subject_id: event.subject_id,
        status: "pending"
      })
    )
    |> Multi.run(:steps, fn repo, %{run: run} ->
      inserted =
        Enum.map(steps, fn step ->
          repo.insert!(
            AutomationRunStep.changeset(%AutomationRunStep{}, %{
              run_id: run.id,
              workflow_step_id: step.id,
              name: step.name,
              action: step.action,
              status: "pending",
              scheduled_for: WorkflowStep.scheduled_for(step, now),
              position: step.position
            })
          )
        end)

      {:ok, inserted}
    end)
    |> Multi.update(:workflow, Workflow.ran_changeset(workflow, now))
    |> Repo.transaction()
    |> case do
      {:ok, _} ->
        :ok

      {:error, :run, changeset, _} ->
        if duplicate_run?(changeset), do: :already_run, else: {:error, changeset}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  ## Running steps

  @doc """
  Steps that are due and not blocked on a person.

  Ordered by schedule so a delayed step never overtakes an earlier one in the
  same run.
  """
  def due_steps(now \\ DateTime.utc_now(), limit \\ @drain_batch) do
    Repo.all(
      from s in AutomationRunStep,
        where: s.status == "pending" and (is_nil(s.scheduled_for) or s.scheduled_for <= ^now),
        order_by: [asc: s.scheduled_for, asc: s.position],
        limit: ^limit,
        preload: [run: :workflow]
    )
  end

  @doc """
  Park a step for approval, storing the rendered preview.

  The preview is what a person will actually approve — the real subject and
  body, not a description of them. Approving something you cannot read is not
  approval.
  """
  def request_approval(%AutomationRunStep{} = step, preview) when is_map(preview) do
    Multi.new()
    |> Multi.update(:step, AutomationRunStep.awaiting_approval_changeset(step, preview))
    |> Multi.update(:run, fn _ ->
      AutomationRun.awaiting_approval_changeset(Repo.get!(AutomationRun, step.run_id))
    end)
    |> Repo.transaction()
    |> unwrap(:step)
  end

  @doc "Everything waiting on a person in this studio. One indexed query."
  def awaiting_approval(%Scope{} = scope) do
    Repo.all(
      from s in AutomationRunStep,
        join: r in AutomationRun,
        on: r.id == s.run_id,
        where: r.studio_id == ^Scope.studio_id(scope) and s.status == "awaiting_approval",
        order_by: [asc: s.inserted_at],
        preload: [run: :workflow]
    )
  end

  def approve_step(%Scope{} = scope, step_id) do
    with :ok <- Authorization.authorize(scope, :"workflow.write"),
         {:ok, step} <- fetch_step(scope, step_id) do
      step |> AutomationRunStep.approved_changeset(scope.user) |> Repo.update()
    end
  end

  def reject_step(%Scope{} = scope, step_id) do
    with :ok <- Authorization.authorize(scope, :"workflow.write"),
         {:ok, step} <- fetch_step(scope, step_id) do
      Multi.new()
      |> Multi.update(:step, AutomationRunStep.rejected_changeset(step, scope.user))
      |> Multi.update(:run, fn _ ->
        AutomationRun.cancelled_changeset(
          Repo.get!(AutomationRun, step.run_id),
          "a step was rejected"
        )
      end)
      |> Repo.transaction()
      |> unwrap(:step)
    end
  end

  @doc "Record a step's outcome, and finish the run when it was the last one."
  def complete_step(%AutomationRunStep{} = step, result \\ %{}) do
    Multi.new()
    |> Multi.update(:step, AutomationRunStep.completed_changeset(step, result))
    |> Multi.run(:run, fn repo, _ -> maybe_finish_run(repo, step.run_id) end)
    |> Repo.transaction()
    |> unwrap(:step)
  end

  def fail_step(%AutomationRunStep{} = step, error) do
    Multi.new()
    |> Multi.update(:step, AutomationRunStep.failed_changeset(step, error))
    |> Multi.update(:run, fn _ ->
      AutomationRun.failed_changeset(Repo.get!(AutomationRun, step.run_id), error)
    end)
    |> Repo.transaction()
    |> unwrap(:step)
  end

  ## Nurture sequences

  def list_sequences(%Scope{} = scope) do
    NurtureSequence
    |> Scoped.for_studio(scope)
    |> preload(:steps)
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  def create_sequence(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"workflow.write") do
      %NurtureSequence{}
      |> NurtureSequence.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
    end
  end

  def fetch_sequence(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"workflow.read") do
      case NurtureSequence |> Scoped.for_studio(scope) |> preload(:steps) |> Repo.get(id) do
        nil -> {:error, :not_found}
        sequence -> {:ok, sequence}
      end
    end
  end

  def update_sequence(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"workflow.write"),
         {:ok, sequence} <- fetch_sequence(scope, id) do
      sequence |> NurtureSequence.changeset(attrs) |> Repo.update()
    end
  end

  def change_sequence(sequence \\ %NurtureSequence{}, attrs \\ %{}),
    do: NurtureSequence.changeset(sequence, attrs)

  def change_workflow(workflow \\ %Workflow{}, attrs \\ %{}),
    do: Workflow.changeset(workflow, attrs)

  ## Activity log

  @doc "The history a photographer reads, newest first."
  def activity(%Scope{} = scope, opts \\ []) do
    ActivityLog
    |> Scoped.for_studio(scope)
    |> then(fn q ->
      case {opts[:subject_type], opts[:subject_id]} do
        {nil, _} -> q
        {type, id} -> where(q, [l], l.subject_type == ^type and l.subject_id == ^id)
      end
    end)
    |> order_by([l], desc: l.occurred_at)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> Repo.all()
  end

  @doc """
  Replay a workflow against history to preview what it would have done.

  Reads events, matches them, and returns the count — without writing anything.
  This is what lets a studio see the blast radius of a rule before switching it
  on, rather than discovering it in their clients' inboxes.
  """
  def preview_workflow(%Scope{} = scope, %Workflow{} = workflow, opts \\ []) do
    since =
      Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -90 * 24 * 60 * 60, :second))

    Repo.all(
      from e in OutboxEvent,
        where:
          e.studio_id == ^Scope.studio_id(scope) and e.name == ^workflow.trigger_event and
            e.occurred_at >= ^since,
        order_by: [desc: e.occurred_at],
        limit: 500
    )
    |> Enum.filter(&Workflow.matches?(%{workflow | active: true}, &1.payload))
  end

  ## Internals

  defp maybe_finish_run(repo, run_id) do
    remaining =
      repo.aggregate(
        from(s in AutomationRunStep,
          where: s.run_id == ^run_id and s.status in ^AutomationRunStep.actionable_statuses()
        ),
        :count
      )

    run = repo.get!(AutomationRun, run_id)

    if remaining == 0 do
      repo.update(AutomationRun.completed_changeset(run))
    else
      repo.update(AutomationRun.started_changeset(run))
    end
  end

  defp fetch_step(%Scope{} = scope, step_id) do
    query =
      from s in AutomationRunStep,
        join: r in AutomationRun,
        on: r.id == s.run_id,
        where: s.id == ^step_id and r.studio_id == ^Scope.studio_id(scope)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      step -> {:ok, step}
    end
  end

  defp duplicate_run?(%Ecto.Changeset{errors: errors}),
    do: Enum.any?(errors, fn {field, _} -> field in [:workflow_id, :event_id] end)

  defp unwrap({:ok, changes}, key), do: {:ok, Map.fetch!(changes, key)}
  defp unwrap({:error, _step, %Ecto.Changeset{} = changeset, _}, _key), do: {:error, changeset}
  defp unwrap({:error, _step, reason, _}, _key), do: {:error, reason}
end
