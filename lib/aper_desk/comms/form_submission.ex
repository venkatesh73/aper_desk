defmodule AperDesk.Comms.FormSubmission do
  @moduledoc """
  One completed enquiry form.

  The raw answers are kept even after a lead is created from them, so a bad
  mapping can be diagnosed against what the client actually typed rather than
  against what the app decided it meant.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Comms.LeadCaptureForm
  alias AperDesk.Crm.Lead

  schema "form_submissions" do
    belongs_to :form, LeadCaptureForm
    belongs_to :studio, Studio
    belongs_to :lead, Lead

    field :answers, :map, default: %{}
    field :ip_address, :string
    field :user_agent, :string
    field :referrer, :string

    timestamps(updated_at: false)
  end

  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [
      :form_id,
      :studio_id,
      :lead_id,
      :answers,
      :ip_address,
      :user_agent,
      :referrer
    ])
    |> validate_required([:form_id, :studio_id])
    |> foreign_key_constraint(:form_id)
  end

  def answer(%__MODULE__{answers: answers}, key), do: Map.get(answers || %{}, key)
end
