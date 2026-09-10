defmodule AperDesk.Automation.WorkflowStep do
  @moduledoc """
  One thing a workflow does, after an optional delay.

  `approval_mode` is nullable and falls back to the workflow's setting, so a
  studio can run a workflow on auto but still hold the one step that sends a
  quote for review.
  """
  use AperDesk.Schema

  alias AperDesk.Automation.Workflow

  @actions ~w(
    send_email send_template create_task assign_owner change_stage
    add_tag schedule_reminder create_invoice notify_team
    request_review start_nurture stop_nurture webhook
  )
  @approval_modes ~w(auto ask)

  # No timestamps: steps are a definition owned by their workflow, and the
  # workflow's own updated_at is the meaningful one.
  @timestamps_opts []

  schema "workflow_steps" do
    belongs_to :workflow, Workflow

    field :name, :string
    field :action, :string
    field :config, :map, default: %{}
    field :delay_minutes, :integer, default: 0
    field :approval_mode, :string
    field :position, :integer, default: 0
    field :active, :boolean, default: true
  end

  def actions, do: @actions
  def approval_modes, do: @approval_modes

  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :workflow_id,
      :name,
      :action,
      :config,
      :delay_minutes,
      :approval_mode,
      :position,
      :active
    ])
    |> validate_required([:name, :action])
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:approval_mode, @approval_modes)
    |> validate_number(:delay_minutes, greater_than_or_equal_to: 0)
    |> validate_config()
  end

  @doc "When this step should run, given the moment its run started."
  def scheduled_for(%__MODULE__{delay_minutes: delay}, from),
    do: DateTime.add(from, (delay || 0) * 60, :second)

  @doc "A human-readable description, for the run log and the workflow editor."
  def describe(%__MODULE__{action: action, name: name, delay_minutes: 0}),
    do: "#{name} (#{humanize(action)}), immediately"

  def describe(%__MODULE__{action: action, name: name, delay_minutes: delay}),
    do: "#{name} (#{humanize(action)}), after #{format_delay(delay)}"

  defp humanize(action), do: String.replace(action, "_", " ")

  defp format_delay(minutes) when minutes < 60, do: "#{minutes} min"
  defp format_delay(minutes) when minutes < 1440, do: "#{div(minutes, 60)} h"
  defp format_delay(minutes), do: "#{div(minutes, 1440)} d"

  # Each action needs its own config keys. Validating here means a broken step
  # is caught in the editor rather than at 6am when the workflow fires.
  defp validate_config(changeset) do
    config = get_field(changeset, :config) || %{}

    required =
      case get_field(changeset, :action) do
        "send_template" -> ["template_id"]
        "send_email" -> ["subject", "body"]
        "change_stage" -> ["stage"]
        "assign_owner" -> ["user_id"]
        "add_tag" -> ["tag"]
        "create_task" -> ["title"]
        "webhook" -> ["url"]
        "start_nurture" -> ["sequence_id"]
        _ -> []
      end

    case Enum.reject(required, &present?(config, &1)) do
      [] -> changeset
      missing -> add_error(changeset, :config, "is missing #{Enum.join(missing, ", ")}")
    end
  end

  defp present?(config, key) do
    case Map.get(config, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
