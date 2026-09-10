defmodule AperDesk.Events do
  @moduledoc """
  Appending domain events and activity-log entries inside the transaction that
  caused them.

  This is the transactional outbox, and it is the reason automation in this
  system is durable rather than best-effort. The alternative — commit the
  change, then enqueue a job — has a window between the two in which the
  process can die, and anything lost in that window is lost silently and
  forever. Here the event is part of the same commit as the row it describes:
  either both are durable or neither happened.

  A separate drain turns unprocessed events into automation runs. Because the
  drain is the only writer of `automation_runs`, and it is guarded by a unique
  index on `(workflow_id, event_id)`, replaying it is harmless.

  Everything here composes onto an `Ecto.Multi` rather than running its own
  transaction, so the caller keeps control of the boundary. A function that
  opens its own transaction cannot be made part of a larger one.
  """

  alias AperDesk.Automation.{ActivityLog, OutboxEvent}
  alias AperDesk.Scope
  alias Ecto.Multi

  @doc """
  Append an outbox event for the record produced by an earlier Multi step.

  `subject_key` names that step, so the event can carry an id that does not
  exist until the insert runs.

      Multi.new()
      |> Multi.insert(:lead, changeset)
      |> Events.emit(:lead, "lead.created", scope)
  """
  def emit(multi, subject_key, name, %Scope{} = scope, opts \\ []) do
    Multi.insert(multi, {:event, name}, fn changes ->
      subject = Map.fetch!(changes, subject_key)

      OutboxEvent.new(
        Scope.studio_id(scope),
        name,
        subject,
        build_payload(subject, opts),
        actor_id: Scope.user_id(scope)
      )
    end)
  end

  @doc """
  Append a human-readable activity entry.

  Separate from `emit/5` because the two answer different questions: an outbox
  event exists to drive automation, an activity entry exists to be read by a
  photographer. Writing every event to the log would bury the six things they
  care about under a hundred they do not.
  """
  def log(multi, subject_key, action, summary, %Scope{} = scope, opts \\ []) do
    Multi.insert(multi, {:activity, action, subject_key}, fn changes ->
      subject = Map.fetch!(changes, subject_key)

      ActivityLog.new(
        Scope.studio_id(scope),
        action,
        subject,
        summary,
        Keyword.merge(
          [
            actor_id: Scope.user_id(scope),
            actor_label: actor_label(scope)
          ],
          opts
        )
      )
    end)
  end

  @doc """
  Emit an event and log an activity entry in one call — the common case for a
  change a person made and automation should react to.
  """
  def record(multi, subject_key, name, summary, %Scope{} = scope, opts \\ []) do
    multi
    |> emit(subject_key, name, scope, opts)
    |> log(subject_key, name, summary, scope, opts)
  end

  @doc """
  Emit an event for a record that already exists, outside a Multi.

  Only for callers that are already inside `Repo.transaction/1`. Calling this
  on its own commits the event independently of whatever it describes, which
  defeats the entire point of the outbox — so it takes the repo explicitly to
  make the transactional context visible at the call site.
  """
  def emit_now(repo, %Scope{} = scope, name, subject, payload \\ %{}) do
    Scope.studio_id(scope)
    |> OutboxEvent.new(name, subject, payload, actor_id: Scope.user_id(scope))
    |> repo.insert()
  end

  defp build_payload(subject, opts) do
    case Keyword.get(opts, :payload) do
      nil -> default_payload(subject)
      payload when is_map(payload) -> Map.merge(default_payload(subject), payload)
      fun when is_function(fun, 1) -> Map.merge(default_payload(subject), fun.(subject))
    end
  end

  # Carrying the fields workflows filter on means a rule can be matched without
  # re-reading the subject, which keeps the drain a single pass over events.
  defp default_payload(subject) do
    subject
    |> Map.take([:shoot_type, :stage, :status, :kind, :source, :currency])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp actor_label(%Scope{user: nil}), do: "Automation"
  defp actor_label(%Scope{user: user}), do: user.name
end
