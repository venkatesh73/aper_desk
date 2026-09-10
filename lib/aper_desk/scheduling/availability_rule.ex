defmodule AperDesk.Scheduling.AvailabilityRule do
  @moduledoc """
  Recurring weekly availability, used by the public booking page.

  Times are stored as minutes past midnight in the studio's own time zone,
  not as UTC instants. "I shoot Saturdays from 9" is a statement about local
  wall-clock time, and it must keep meaning 9am after a daylight-saving
  change — which storing an absolute offset would quietly break twice a year.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}

  @days ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

  schema "availability_rules" do
    belongs_to :studio, Studio
    belongs_to :user, User

    field :day_of_week, :integer
    field :starts_at_minute, :integer
    field :ends_at_minute, :integer
    field :bookable, :boolean, default: true

    timestamps()
  end

  def day_name(day) when day in 0..6, do: Enum.at(@days, day)

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :studio_id,
      :user_id,
      :day_of_week,
      :starts_at_minute,
      :ends_at_minute,
      :bookable
    ])
    |> validate_required([:studio_id, :day_of_week, :starts_at_minute, :ends_at_minute])
    |> validate_inclusion(:day_of_week, 0..6)
    |> validate_number(:starts_at_minute, greater_than_or_equal_to: 0, less_than: 1440)
    |> validate_number(:ends_at_minute, greater_than: 0, less_than_or_equal_to: 1440)
    |> validate_order()
  end

  @doc "Whether `datetime`, read in `time_zone`, falls inside this rule."
  def covers?(%__MODULE__{} = rule, %DateTime{} = datetime, time_zone) do
    case DateTime.shift_zone(datetime, time_zone) do
      {:ok, local} ->
        minute = local.hour * 60 + local.minute

        Date.day_of_week(local, :sunday) - 1 == rule.day_of_week and
          minute >= rule.starts_at_minute and minute < rule.ends_at_minute

      _ ->
        false
    end
  end

  @doc "Render as `\"09:00\"`."
  def format_minute(minute) when is_integer(minute) do
    hours = minute |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    minutes = minute |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{hours}:#{minutes}"
  end

  defp validate_order(changeset) do
    from = get_field(changeset, :starts_at_minute)
    to = get_field(changeset, :ends_at_minute)

    if is_integer(from) and is_integer(to) and to <= from do
      add_error(changeset, :ends_at_minute, "must be after the start time")
    else
      changeset
    end
  end
end
