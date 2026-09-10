defmodule AperDesk.Automation.NurtureStep do
  @moduledoc """
  One message in a nurture sequence, at `day_offset` days after entry.

  Offsets are relative to entry rather than to the previous step, so reordering
  or removing a step does not silently shift every message after it.
  """
  use AperDesk.Schema

  alias AperDesk.Automation.NurtureSequence
  alias AperDesk.Comms.EmailTemplate

  @timestamps_opts []

  schema "nurture_steps" do
    belongs_to :sequence, NurtureSequence
    belongs_to :template, EmailTemplate

    field :day_offset, :integer
    field :subject, :string
    field :body, :string
    field :position, :integer, default: 0
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:sequence_id, :template_id, :day_offset, :subject, :body, :position])
    |> validate_required([:day_offset])
    |> validate_number(:day_offset, greater_than_or_equal_to: 0)
    |> validate_content()
  end

  @doc "When this step is due, given when the lead entered the sequence."
  def due_at(%__MODULE__{day_offset: offset}, entered_at),
    do: DateTime.add(entered_at, offset * 24 * 60 * 60, :second)

  # A step needs either a template to send or its own copy. Neither means the
  # sequence has a silent gap in it.
  defp validate_content(changeset) do
    has_template = get_field(changeset, :template_id) != nil
    has_body = get_field(changeset, :body) not in [nil, ""]

    if has_template or has_body do
      changeset
    else
      add_error(changeset, :body, "a step needs either a template or its own message")
    end
  end
end
