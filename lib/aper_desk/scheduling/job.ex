defmodule AperDesk.Scheduling.Job do
  @moduledoc """
  A confirmed (or pencilled) shoot.

  `starts_at`/`ends_at` are the client-facing window. The travel buffers are
  stored beside them rather than baked in, so the calendar can show a couple
  "11:00–22:00" while the clash checker reserves the two hours of driving that
  makes booking a second job that morning impossible.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Catalog.Package
  alias AperDesk.Crm.{Contact, Lead}
  alias AperDesk.Scheduling.Assignment

  @statuses ~w(pencilled confirmed shot delivered cancelled)

  schema "jobs" do
    belongs_to :studio, Studio
    belongs_to :lead, Lead
    belongs_to :contact, Contact
    belongs_to :package, Package

    field :reference, :string, read_after_writes: true
    field :title, :string
    field :shoot_type, :string, default: "other"
    field :status, :string, default: "confirmed"

    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :time_zone, :string, default: "Etc/UTC"

    field :travel_before_minutes, :integer, default: 0
    field :travel_after_minutes, :integer, default: 0

    field :venue_name, :string
    field :venue_address, :string
    field :city, :string
    field :country_code, :string
    field :venue_notes, :string
    field :shot_list, :string

    field :value_cents, :integer
    field :value_currency, :string

    field :gallery_due_on, :date
    field :completed_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    field :cancellation_reason, :string

    has_many :assignments, Assignment

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :studio_id,
      :lead_id,
      :contact_id,
      :package_id,
      :reference,
      :title,
      :shoot_type,
      :status,
      :starts_at,
      :ends_at,
      :time_zone,
      :travel_before_minutes,
      :travel_after_minutes,
      :venue_name,
      :venue_address,
      :city,
      :country_code,
      :venue_notes,
      :shot_list,
      :value_cents,
      :value_currency,
      :gallery_due_on
    ])
    |> validate_required([:studio_id, :title, :starts_at, :ends_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:travel_before_minutes, greater_than_or_equal_to: 0)
    |> validate_number(:travel_after_minutes, greater_than_or_equal_to: 0)
    |> validate_end_after_start()
    |> unique_constraint([:studio_id, :reference])
  end

  @doc """
  The window the job actually occupies, buffers included. This — not
  `starts_at..ends_at` — is what goes into an assignment's `period`.
  """
  def occupied_window(%__MODULE__{} = job) do
    from = DateTime.add(job.starts_at, -(job.travel_before_minutes || 0) * 60, :second)
    to = DateTime.add(job.ends_at, (job.travel_after_minutes || 0) * 60, :second)
    {from, to}
  end

  defp validate_end_after_start(changeset) do
    with %DateTime{} = from <- get_field(changeset, :starts_at),
         %DateTime{} = to <- get_field(changeset, :ends_at),
         true <- DateTime.compare(to, from) != :gt do
      add_error(changeset, :ends_at, "must be after the start time")
    else
      _ -> changeset
    end
  end
end
