defmodule AperDesk.Automation.ActivityLog do
  @moduledoc """
  The history a photographer actually reads.

  Deliberately separate from `OutboxEvent`, which is machinery. An outbox event
  exists to drive automation and is written for every domain change; an activity
  log entry exists to be read by a person and is written only when something
  worth telling them about happened. Keeping them apart means the log can be
  edited for signal without breaking automation, and automation can add events
  without flooding the log.

  `actor_label` is denormalised so the log still reads correctly after a team
  member is removed — "Deleted user" is a worse answer than the name that acted.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}

  schema "activity_logs" do
    belongs_to :studio, Studio
    belongs_to :actor, User

    field :actor_label, :string
    field :subject_type, :string
    field :subject_id, :binary_id
    field :action, :string
    field :summary, :string
    field :reason, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  @doc """
  Build a log entry for `subject`.

  Pass `reason:` whenever the actor is automation — "sent because the shoot is
  in 7 days" is the difference between a log a studio trusts and one it ignores.
  """
  def new(studio_id, action, subject, summary, opts \\ []) do
    %__MODULE__{}
    |> changeset(%{
      studio_id: studio_id,
      action: action,
      subject_type: subject_type(subject),
      subject_id: subject.id,
      summary: summary,
      actor_id: Keyword.get(opts, :actor_id),
      actor_label: Keyword.get(opts, :actor_label, default_label(opts)),
      reason: Keyword.get(opts, :reason),
      metadata: Keyword.get(opts, :metadata, %{}),
      occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now())
    })
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :studio_id,
      :actor_id,
      :actor_label,
      :subject_type,
      :subject_id,
      :action,
      :summary,
      :reason,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:studio_id, :subject_type, :subject_id, :action, :summary])
    |> put_occurred_at()
    |> foreign_key_constraint(:studio_id)
  end

  @doc "Whether this entry was written by automation rather than a person."
  def automated?(%__MODULE__{actor_id: nil}), do: true
  def automated?(%__MODULE__{}), do: false

  defp subject_type(%module{}), do: module |> Module.split() |> List.last()

  defp default_label(opts),
    do: if(Keyword.get(opts, :actor_id), do: nil, else: "Automation")

  defp put_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil -> put_change(changeset, :occurred_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
