defmodule AperDeskWeb.StudioOptions do
  @moduledoc """
  The choices a studio is offered for how it reads dates, money and time.

  Shared by the first-run setup screen and the settings screen. They ask the
  same questions and must offer the same answers: a zone or a format available
  in one and missing from the other is a studio that cannot change back what it
  chose on its first day.

  These are presentation decisions — which zones are worth listing, how to word
  a format — so they live in the web layer rather than in `AperDesk.Formats`,
  which owns what the choices actually mean.
  """

  alias AperDesk.Accounts.Studio
  alias AperDesk.Money

  @time_zones [
    "Etc/UTC",
    "Europe/London",
    "Europe/Dublin",
    "Europe/Lisbon",
    "Europe/Madrid",
    "Europe/Paris",
    "Europe/Amsterdam",
    "Europe/Brussels",
    "Europe/Zurich",
    "Europe/Berlin",
    "Europe/Vienna",
    "Europe/Rome",
    "Europe/Stockholm",
    "Europe/Oslo",
    "Europe/Copenhagen",
    "Europe/Warsaw",
    "Europe/Prague",
    "Europe/Athens",
    "Europe/Istanbul",
    "Europe/Moscow",
    "Asia/Dubai",
    "Asia/Karachi",
    "Asia/Kolkata",
    "Asia/Colombo",
    "Asia/Dhaka",
    "Asia/Bangkok",
    "Asia/Singapore",
    "Asia/Hong_Kong",
    "Asia/Shanghai",
    "Asia/Tokyo",
    "Asia/Seoul",
    "Australia/Perth",
    "Australia/Adelaide",
    "Australia/Sydney",
    "Pacific/Auckland",
    "America/New_York",
    "America/Toronto",
    "America/Chicago",
    "America/Denver",
    "America/Los_Angeles",
    "America/Vancouver",
    "America/Mexico_City",
    "America/Bogota",
    "America/Sao_Paulo",
    "America/Argentina/Buenos_Aires",
    "Africa/Casablanca",
    "Africa/Lagos",
    "Africa/Nairobi",
    "Africa/Johannesburg"
  ]

  @doc """
  The zone list, with `zone` folded in if it is not already there.

  A curated list rather than the full IANA set: a 400-entry dropdown is worse
  than thirty that cover where photographers actually work. The studio's own
  zone is always present even when it is not on the list, because a setting you
  cannot see is a setting you cannot change.
  """
  def time_zones(zone \\ nil)

  def time_zones(nil), do: @time_zones

  def time_zones(zone) when is_binary(zone) do
    if zone in @time_zones, do: @time_zones, else: Enum.sort([zone | @time_zones])
  end

  @doc "Whether a string names a zone the system can actually shift into."
  def valid_zone?(zone) when is_binary(zone) do
    match?({:ok, _}, DateTime.shift_zone(DateTime.utc_now(), zone))
  end

  def valid_zone?(_zone), do: false

  def time_zone_options(zone \\ nil),
    do: Enum.map(time_zones(zone), &{String.replace(&1, "_", " "), &1})

  def currency_options,
    do: Enum.map(Money.supported_currencies(), &{"#{&1} · #{Money.symbol(&1)}", &1})

  def date_format_options, do: Enum.map(Studio.date_formats(), &{date_format_label(&1), &1})
  def time_format_options, do: Enum.map(Studio.time_formats(), &{time_format_label(&1), &1})
  def week_start_options, do: Enum.map(Studio.week_starts(), &{week_start_label(&1), &1})

  def date_format_label("dmy"), do: "Day first — 10/09/2026"
  def date_format_label("mdy"), do: "Month first — 09/10/2026"
  def date_format_label("iso"), do: "ISO — 2026-09-10"
  def date_format_label("long"), do: "Written — 10 Sep 2026"

  def time_format_label("12h"), do: "12-hour — 2:30 pm"
  def time_format_label("24h"), do: "24-hour — 14:30"

  def week_start_label("monday"), do: "Monday"
  def week_start_label("sunday"), do: "Sunday"

  @doc "Reply-time targets, in minutes."
  def sla_options do
    [
      {"Within 1 hour", 60},
      {"Within 4 hours", 240},
      {"Within 12 hours", 720},
      {"Within 24 hours", 1440},
      {"Within 2 days", 2880}
    ]
  end
end
