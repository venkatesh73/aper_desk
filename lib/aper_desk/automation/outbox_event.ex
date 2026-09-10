defmodule AperDesk.Automation.OutboxEvent do
  @moduledoc """
  A domain event, written in the same transaction as the change it describes.

  This is the transactional outbox pattern, and it buys three things the
  obvious alternative (enqueue a job after committing) cannot:

    * nothing is lost if the process dies between the commit and the enqueue —
      the event is already durable, part of the same commit
    * every automation run can point at the event that caused it, so "why did
      this client get that email?" has an answer
    * a rule can be replayed over historical events to preview what it would
      have done, before a studio switches it on

  A single drain job turns unprocessed events into `AutomationRun` rows.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}

  schema "outbox_events" do
    belongs_to :studio, Studio
    belongs_to :actor, User

    field :name, :string
    field :subject_type, :string
    field :subject_id, :binary_id
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime_usec
    field :processed_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :last_error, :string

    timestamps(updated_at: false)
  end

  @doc """
  Build an event for `subject`.

  The subject type is derived from the struct rather than passed in, so it can
  never disagree with the id beside it.
  """
  def new(studio_id, name, subject, payload \\ %{}, opts \\ []) do
    %__MODULE__{}
    |> changeset(%{
      studio_id: studio_id,
      name: name,
      subject_type: subject_type(subject),
      subject_id: subject.id,
      actor_id: Keyword.get(opts, :actor_id),
      payload: payload,
      occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now())
    })
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :studio_id,
      :name,
      :subject_type,
      :subject_id,
      :actor_id,
      :payload,
      :occurred_at
    ])
    |> validate_required([:studio_id, :name, :subject_type, :subject_id])
    |> put_occurred_at()
    |> validate_format(:name, ~r/^[a-z_]+\.[a-z_]+$/,
      message: "must look like subject.verb, e.g. lead.created"
    )
    |> foreign_key_constraint(:studio_id)
  end

  @doc "Mark an event as drained. Idempotent — re-running the drain is harmless."
  def processed_changeset(event, at \\ DateTime.utc_now()),
    do: change(event, processed_at: event.processed_at || at, last_error: nil)

  @doc "Record a failed drain attempt so a poison event can be found and skipped."
  def failed_changeset(event, error),
    do: change(event, attempts: (event.attempts || 0) + 1, last_error: error)

  def processed?(%__MODULE__{processed_at: %DateTime{}}), do: true
  def processed?(%__MODULE__{}), do: false

  @doc "The short name of the schema module backing `subject`, e.g. `\"Lead\"`."
  def subject_type(%module{}), do: module |> Module.split() |> List.last()

  defp put_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil -> put_change(changeset, :occurred_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
