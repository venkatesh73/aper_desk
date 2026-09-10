defmodule AperDesk.Automation.Workflow do
  @moduledoc """
  A rule: when this happens, do these things.

  A workflow fires from a named domain event rather than from a polled query,
  which is what makes "why did this run?" answerable — every run points at the
  outbox event that caused it.

  `approval_mode` defaults to `"ask"`. The default is deliberate: a studio's
  reputation rides on every message it sends, so automation is opt-in per
  workflow rather than something a studio discovers after the fact.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Automation.WorkflowStep

  @approval_modes ~w(auto ask)

  # The domain events a workflow can hang off. Kept as a closed list so a typo
  # in a trigger name fails at save time instead of producing a rule that
  # silently never fires.
  @trigger_events ~w(
    lead.created lead.stage_changed lead.overdue lead.won lead.lost
    job.created job.confirmed job.completed job.cancelled job.upcoming
    quote.sent quote.accepted quote.declined quote.expired
    contract.sent contract.signed
    invoice.sent invoice.paid invoice.overdue
    gallery.delivered gallery.viewed gallery.expiring
    form.submitted email.received
  )

  schema "workflows" do
    belongs_to :studio, Studio

    field :name, :string
    field :description, :string
    field :shoot_type, :string
    field :trigger_event, :string
    field :trigger_conditions, :map, default: %{}
    field :active, :boolean, default: false

    field :approval_mode, :string, default: "ask"
    field :run_count, :integer, default: 0
    field :last_run_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec

    has_many :steps, WorkflowStep, foreign_key: :workflow_id, on_replace: :delete

    timestamps()
  end

  def approval_modes, do: @approval_modes
  def trigger_events, do: @trigger_events

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [
      :studio_id,
      :name,
      :description,
      :shoot_type,
      :trigger_event,
      :trigger_conditions,
      :active,
      :approval_mode
    ])
    |> validate_required([:studio_id, :name, :trigger_event])
    |> validate_inclusion(:trigger_event, @trigger_events)
    |> validate_inclusion(:approval_mode, @approval_modes)
    |> cast_assoc(:steps)
    |> validate_has_steps()
    |> foreign_key_constraint(:studio_id)
  end

  @doc "Record that the workflow fired."
  def ran_changeset(workflow, at \\ DateTime.utc_now()),
    do: change(workflow, run_count: (workflow.run_count || 0) + 1, last_run_at: at)

  @doc """
  Whether an event matches this workflow's conditions.

  Conditions are a flat map of `field => expected`, compared against the event
  payload. `expected` may be a list, meaning "any of". Kept intentionally simple:
  a condition language nobody can predict the behaviour of is worse than one
  that occasionally needs a second workflow.
  """
  def matches?(%__MODULE__{active: false}, _payload), do: false

  def matches?(%__MODULE__{trigger_conditions: conditions, shoot_type: shoot_type}, payload)
      when is_map(payload) do
    shoot_type_matches?(shoot_type, payload) and conditions_match?(conditions, payload)
  end

  @doc "Whether a step's outcome needs a human before it takes effect."
  def requires_approval?(%__MODULE__{approval_mode: mode}, step_mode),
    do: (step_mode || mode) == "ask"

  defp shoot_type_matches?(nil, _payload), do: true

  defp shoot_type_matches?(shoot_type, payload),
    do: Map.get(payload, "shoot_type") in [nil, shoot_type]

  defp conditions_match?(conditions, _payload) when conditions in [nil, %{}], do: true

  defp conditions_match?(conditions, payload) do
    Enum.all?(conditions, fn {key, expected} ->
      actual = Map.get(payload, key)

      case expected do
        list when is_list(list) -> actual in list
        value -> actual == value
      end
    end)
  end

  # A workflow with no steps is active, matches events, and does nothing — the
  # worst possible failure mode, because it looks like it is working.
  defp validate_has_steps(changeset) do
    steps =
      changeset
      |> get_field(:steps)
      |> List.wrap()
      |> Enum.reject(&match?(%{action: :replace}, &1))

    if get_field(changeset, :active) and steps == [] do
      add_error(changeset, :steps, "an active workflow needs at least one step")
    else
      changeset
    end
  end
end
