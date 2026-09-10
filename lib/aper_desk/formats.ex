defmodule AperDesk.Formats do
  @moduledoc """
  Renders dates and times the way a studio asked for them.

  The reason this exists rather than a `strftime` call at each site: 10/09/2026
  and 09/10/2026 are the same eight characters and a month apart, and a
  photographer reading the wrong one turns up on the wrong day. Whose
  convention applies is a property of the studio, so it is read from the studio
  rather than from the server's locale.

  Every function takes a `%Scope{}` or a `%Studio{}` and falls back to sensible
  defaults for an anonymous caller — the public gallery and booking pages have
  no studio scope but still show dates.
  """

  alias AperDesk.Accounts.Studio
  alias AperDesk.Scope

  @doc "A date in the studio's format: `10/09/2026`, `09/10/2026`, `2026-09-10` or `10 Sep 2026`."
  def date(subject, date_or_datetime)

  def date(_subject, nil), do: nil

  def date(subject, %DateTime{} = datetime) do
    case DateTime.shift_zone(datetime, time_zone(subject)) do
      {:ok, local} -> date(subject, DateTime.to_date(local))
      _ -> date(subject, DateTime.to_date(datetime))
    end
  end

  def date(subject, %Date{} = value) do
    case date_format(subject) do
      "mdy" -> Calendar.strftime(value, "%m/%d/%Y")
      "iso" -> Date.to_iso8601(value)
      "long" -> Calendar.strftime(value, "%-d %b %Y")
      _dmy -> Calendar.strftime(value, "%d/%m/%Y")
    end
  end

  @doc "A time in the studio's format, in the studio's zone: `14:30` or `2:30 pm`."
  def time(subject, datetime)

  def time(_subject, nil), do: nil

  def time(subject, %DateTime{} = datetime) do
    local =
      case DateTime.shift_zone(datetime, time_zone(subject)) do
        {:ok, shifted} -> shifted
        _ -> datetime
      end

    case time_format(subject) do
      "12h" -> local |> Calendar.strftime("%-I:%M %p") |> String.downcase()
      _ -> Calendar.strftime(local, "%H:%M")
    end
  end

  def time(subject, %Time{} = value) do
    case time_format(subject) do
      "12h" -> value |> Calendar.strftime("%-I:%M %p") |> String.downcase()
      _ -> Calendar.strftime(value, "%H:%M")
    end
  end

  @doc "Date and time together, e.g. `10/09/2026 · 14:30`."
  def datetime(_subject, nil), do: nil

  def datetime(subject, %DateTime{} = value),
    do: "#{date(subject, value)} · #{time(subject, value)}"

  @doc """
  A friendly label where one helps, falling back to the studio's date format.

  "Today" and "In 3 days" beat any format for something imminent; beyond a
  fortnight the actual date is more use than a countdown.
  """
  def relative_date(subject, value, today \\ nil)

  def relative_date(_subject, nil, _today), do: nil

  def relative_date(subject, %DateTime{} = value, today),
    do: relative_date(subject, DateTime.to_date(value), today)

  def relative_date(subject, %Date{} = value, today) do
    today = today || today_for(subject)

    case Date.diff(value, today) do
      0 -> "Today"
      1 -> "Tomorrow"
      -1 -> "Yesterday"
      days when days > 1 and days <= 14 -> "In #{days} days"
      days when days < -1 and days >= -14 -> "#{abs(days)} days ago"
      _ -> date(subject, value)
    end
  end

  @doc "Today, in the studio's time zone rather than the server's."
  def today_for(subject) do
    case DateTime.shift_zone(DateTime.utc_now(), time_zone(subject)) do
      {:ok, local} -> DateTime.to_date(local)
      _ -> Date.utc_today()
    end
  end

  @doc "The day the studio's week starts on: 1 for Monday, 7 for Sunday."
  def week_start_day(subject) do
    case studio(subject) do
      %Studio{week_starts_on: "sunday"} -> 7
      _ -> 1
    end
  end

  @doc "A worked example of the chosen formats, for the setup screen."
  def sample(subject) do
    at = DateTime.new!(~D[2026-09-10], ~T[14:30:00], "Etc/UTC")
    "#{date(subject, ~D[2026-09-10])} · #{time(subject, at)}"
  end

  ## Internals

  defp studio(%Scope{studio: studio}), do: studio
  defp studio(%Studio{} = studio), do: studio
  defp studio(_other), do: nil

  defp time_zone(subject) do
    case studio(subject) do
      %Studio{time_zone: zone} when is_binary(zone) -> zone
      _ -> "Etc/UTC"
    end
  end

  defp date_format(subject) do
    case studio(subject) do
      %Studio{date_format: format} when is_binary(format) -> format
      _ -> "dmy"
    end
  end

  defp time_format(subject) do
    case studio(subject) do
      %Studio{time_format: format} when is_binary(format) -> format
      _ -> "24h"
    end
  end
end
