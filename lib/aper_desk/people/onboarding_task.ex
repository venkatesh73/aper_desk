defmodule AperDesk.People.OnboardingTask do
  @moduledoc """
  One step of getting a new person working.

  Per membership rather than per user: someone who freelances for two studios
  is onboarded twice, and their progress at one says nothing about the other.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Membership, Studio, User}

  @default_tasks [
    "Sign the contract",
    "Share the calendar",
    "Add to the studio's shared drive",
    "Walk through the gear checkout",
    "First shoot shadowed"
  ]

  schema "onboarding_tasks" do
    belongs_to :studio, Studio
    belongs_to :membership, Membership
    belongs_to :done_by, User

    field :label, :string
    field :detail, :string
    field :position, :integer, default: 0
    field :done_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The checklist a new person starts with, so HR is not typing it each time."
  def default_tasks, do: @default_tasks

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:studio_id, :membership_id, :label, :detail, :position])
    |> validate_required([:studio_id, :membership_id, :label])
  end

  def toggle_changeset(%__MODULE__{done_at: nil} = task, user_id),
    do: change(task, done_at: DateTime.utc_now(), done_by_id: user_id)

  def toggle_changeset(%__MODULE__{} = task, _user_id),
    do: change(task, done_at: nil, done_by_id: nil)

  def done?(%__MODULE__{done_at: nil}), do: false
  def done?(%__MODULE__{}), do: true
end
