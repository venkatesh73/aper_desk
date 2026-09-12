defmodule AperDesk.Crm.Lead do
  @moduledoc """
  One piece of work someone asked about.

  The reply-time fields are on the row rather than derived from the message log
  because "who is waiting on us" is the most-run query in the product and it
  runs on every dashboard load. Denormalising it turns a join over every email
  into a partial index scan.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}
  alias AperDesk.Crm.Contact

  @stages ~w(new contacted consult quote_sent booked completed lost)
  @open_stages ~w(new contacted consult quote_sent)
  @shoot_types ~w(wedding portrait newborn family engagement event commercial product real_estate other)
  @sources ~w(manual email form booking referral directory google instagram whatsapp phone import other)

  schema "leads" do
    belongs_to :studio, Studio
    belongs_to :contact, Contact
    belongs_to :owner, User

    field :reference, :string, read_after_writes: true
    field :title, :string
    field :shoot_type, :string, default: "other"
    field :stage, :string, default: "new"

    field :desired_date, :date
    field :desired_end_date, :date
    field :flexible_dates, :boolean, default: false
    field :location, :string
    field :city, :string
    field :country_code, :string
    field :guest_count, :integer

    field :budget_cents, :integer
    field :budget_currency, :string
    field :estimated_value_cents, :integer
    field :estimated_value_currency, :string

    field :source, :string, default: "manual"
    field :source_detail, :string

    field :first_response_due_at, :utc_datetime_usec
    field :first_responded_at, :utc_datetime_usec
    field :last_client_message_at, :utc_datetime_usec
    field :last_studio_message_at, :utc_datetime_usec

    field :lost_reason, :string
    field :won_at, :utc_datetime_usec
    field :lost_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec

    # What the client wrote in their own words. Distinct from `custom_fields`,
    # which is the studio's own defined schema and drops anything undefined.
    field :notes, :string

    field :custom_fields, :map, default: %{}

    timestamps()
  end

  def stages, do: @stages
  def open_stages, do: @open_stages
  def shoot_types, do: @shoot_types
  def sources, do: @sources

  def changeset(lead, attrs) do
    lead
    |> cast(attrs, [
      :studio_id,
      :contact_id,
      :owner_id,
      :reference,
      :title,
      :shoot_type,
      :stage,
      :desired_date,
      :desired_end_date,
      :flexible_dates,
      :location,
      :city,
      :country_code,
      :guest_count,
      :budget_cents,
      :budget_currency,
      :estimated_value_cents,
      :estimated_value_currency,
      :source,
      :source_detail,
      :notes,
      :custom_fields
    ])
    |> validate_required([:studio_id, :title])
    |> validate_inclusion(:stage, @stages)
    |> validate_inclusion(:shoot_type, @shoot_types)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:guest_count, greater_than_or_equal_to: 0)
    |> validate_date_order()
    |> unique_constraint([:studio_id, :reference])
    |> foreign_key_constraint(:studio_id)
  end

  @doc """
  Move a lead along the pipeline, stamping the timestamps that go with the
  destination. Kept separate from `changeset/2` so a stage change is always
  deliberate and always consistent — you cannot land in `lost` without a
  `lost_at`.
  """
  def stage_changeset(lead, stage, attrs \\ %{}) when stage in @stages do
    now = DateTime.utc_now()

    lead
    |> cast(attrs, [:lost_reason])
    |> put_change(:stage, stage)
    |> then(fn cs ->
      case stage do
        "booked" -> put_change(cs, :won_at, lead.won_at || now)
        "lost" -> put_change(cs, :lost_at, now)
        _ -> cs
      end
    end)
    |> then(fn cs ->
      if stage == "lost" and is_nil(get_field(cs, :lost_reason)) do
        add_error(cs, :lost_reason, "is required when marking a lead lost")
      else
        cs
      end
    end)
  end

  @doc "Record that a human replied, which stops the SLA clock."
  def responded_changeset(lead, at \\ DateTime.utc_now()) do
    change(lead, first_responded_at: lead.first_responded_at || at, last_studio_message_at: at)
  end

  @doc "Whether the reply window has passed with nobody having answered."
  def overdue?(
        %__MODULE__{first_responded_at: nil, first_response_due_at: %DateTime{} = due},
        now
      ),
      do: DateTime.compare(now, due) == :gt

  def overdue?(%__MODULE__{}, _now), do: false

  @doc "Whether the lead still counts against the plan's active-lead limit."
  def active?(%__MODULE__{archived_at: nil, stage: stage}), do: stage not in ~w(completed lost)
  def active?(%__MODULE__{}), do: false

  defp validate_date_order(changeset) do
    with %Date{} = from <- get_field(changeset, :desired_date),
         %Date{} = to <- get_field(changeset, :desired_end_date),
         :gt <- Date.compare(from, to) do
      add_error(changeset, :desired_end_date, "must be on or after the start date")
    else
      _ -> changeset
    end
  end
end
