defmodule AperDeskWeb.Graphql.Resolvers.Helpers do
  @moduledoc """
  Presentation helpers shared by resolvers.

  These live on the server rather than in the client because the mobile app and
  the LiveView UI must agree: "in 3 days" and an amber date badge should mean
  the same thing in both, and duplicating the rule in Dart guarantees they
  eventually drift.

  Money crosses the API as a float of major units — the one place a float is
  allowed, and only because it is the last step before display. Every
  calculation upstream is in integer minor units. See `AperDesk.Money`.
  """

  alias AperDesk.Money

  @doc "Two-letter monogram, e.g. \"Anna Bell\" -> \"AB\"."
  def initials(nil), do: "?"

  def initials(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
    |> case do
      "" -> "?"
      value -> value
    end
  end

  @doc "Integer minor units to a float of major units, for display only."
  def to_major(nil, _currency), do: nil

  def to_major(cents, currency) when is_integer(cents) do
    exponent = Money.exponent(currency)
    cents / :math.pow(10, exponent)
  end

  def to_major(%Money{} = money), do: to_major(money.amount, money.currency)

  @doc "A human date label: \"Today\", \"In 3 days\", \"12 Jun 2026\"."
  def date_label(value, today \\ Date.utc_today())

  def date_label(nil, _today), do: nil

  def date_label(%DateTime{} = datetime, today), do: date_label(DateTime.to_date(datetime), today)

  def date_label(%Date{} = date, today) do
    case Date.diff(date, today) do
      0 -> "Today"
      1 -> "Tomorrow"
      -1 -> "Yesterday"
      days when days > 1 and days <= 14 -> "In #{days} days"
      days when days < -1 and days >= -14 -> "#{abs(days)} days ago"
      _ -> Calendar.strftime(date, "%-d %b %Y")
    end
  end

  @doc """
  How urgent a date is, for the badge colour.

  A shoot inside a week is `warning`, one in the past is `critical`. Deriving
  it here means the calendar, the lead list and the mobile app all agree.
  """
  def date_status(value, today \\ Date.utc_today())

  def date_status(nil, _today), do: "none"

  def date_status(%DateTime{} = datetime, today),
    do: date_status(DateTime.to_date(datetime), today)

  def date_status(%Date{} = date, today) do
    case Date.diff(date, today) do
      days when days < 0 -> "past"
      days when days <= 7 -> "soon"
      days when days <= 30 -> "upcoming"
      _ -> "future"
    end
  end

  @doc "Relative time for an activity feed: \"2h ago\"."
  def time_ago(at, now \\ DateTime.utc_now())

  def time_ago(nil, _now), do: ""

  def time_ago(%DateTime{} = at, now) do
    seconds = DateTime.diff(now, at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds < 2_592_000 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(at, "%-d %b")
    end
  end

  @doc "Title-case a stored enum value: `\"quote_sent\"` -> `\"Quote sent\"`."
  def humanise(nil), do: nil

  def humanise(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def humanise(value) when is_atom(value), do: value |> Atom.to_string() |> humanise()

  @doc "Bytes to gigabytes, rounded to one decimal, for the storage meter."
  def to_gb(nil), do: 0.0
  def to_gb(bytes) when is_integer(bytes), do: Float.round(bytes / 1_073_741_824, 1)
end
