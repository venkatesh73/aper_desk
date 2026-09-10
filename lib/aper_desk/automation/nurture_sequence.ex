defmodule AperDesk.Automation.NurtureSequence do
  @moduledoc """
  A drip of follow-ups for a lead that has gone quiet.

  `exit_on_reply` defaults to true and is the single most important setting
  here: a sequence that keeps sending after a client has replied is the fastest
  way to make automation look like spam.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Automation.NurtureStep
  alias AperDesk.Crm.Lead

  schema "nurture_sequences" do
    belongs_to :studio, Studio

    field :name, :string
    field :shoot_type, :string
    field :enter_when_stage, :string
    field :enter_after_days, :integer, default: 3
    field :exit_on_reply, :boolean, default: true
    field :active, :boolean, default: false

    has_many :steps, NurtureStep, foreign_key: :sequence_id, on_replace: :delete

    timestamps()
  end

  def changeset(sequence, attrs) do
    sequence
    |> cast(attrs, [
      :studio_id,
      :name,
      :shoot_type,
      :enter_when_stage,
      :enter_after_days,
      :exit_on_reply,
      :active
    ])
    |> validate_required([:studio_id, :name])
    |> validate_number(:enter_after_days, greater_than_or_equal_to: 0)
    |> validate_inclusion(:enter_when_stage, Lead.stages())
    |> cast_assoc(:steps)
    |> foreign_key_constraint(:studio_id)
  end

  @doc """
  Whether `lead` should enter this sequence now.

  Requires the lead to be in the configured stage, silent for at least
  `enter_after_days`, and still open — a booked or lost lead is never chased.
  """
  def should_enter?(%__MODULE__{active: false}, _lead, _now), do: false

  def should_enter?(%__MODULE__{} = sequence, %Lead{} = lead, now) do
    stage_matches?(sequence, lead) and shoot_type_matches?(sequence, lead) and
      Lead.active?(lead) and silent_long_enough?(sequence, lead, now)
  end

  defp stage_matches?(%__MODULE__{enter_when_stage: nil}, _lead), do: true
  defp stage_matches?(%__MODULE__{enter_when_stage: stage}, %Lead{stage: stage}), do: true
  defp stage_matches?(%__MODULE__{}, %Lead{}), do: false

  defp shoot_type_matches?(%__MODULE__{shoot_type: nil}, _lead), do: true

  defp shoot_type_matches?(%__MODULE__{shoot_type: type}, %Lead{shoot_type: type}), do: true
  defp shoot_type_matches?(%__MODULE__{}, %Lead{}), do: false

  # Measured from the last contact in either direction, so a lead the studio
  # only just emailed is not immediately chased again.
  defp silent_long_enough?(%__MODULE__{enter_after_days: days}, %Lead{} = lead, now) do
    case last_contact_at(lead) do
      nil -> true
      at -> DateTime.diff(now, at, :second) >= days * 24 * 60 * 60
    end
  end

  defp last_contact_at(%Lead{last_client_message_at: nil, last_studio_message_at: at}), do: at
  defp last_contact_at(%Lead{last_client_message_at: at, last_studio_message_at: nil}), do: at

  defp last_contact_at(%Lead{last_client_message_at: a, last_studio_message_at: b}),
    do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
end
