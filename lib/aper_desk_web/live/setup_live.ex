defmodule AperDeskWeb.SetupLive do
  @moduledoc """
  First-run setup, shown once before a new studio can use the app.

  Only the answers the product cannot sensibly guess are asked for. Currency and
  time zone are the two that silently corrupt everything downstream if wrong — a
  quote issued in the wrong currency, a shoot booked on the wrong day — so they
  are required rather than defaulted past and forgotten.

  The date and time formats are shown as a live worked example, because "dmy"
  and "mdy" mean nothing until you see 10/09/2026 next to 09/10/2026 and realise
  they are a month apart.
  """

  use AperDeskWeb, :live_view

  alias AperDesk.Accounts
  alias AperDesk.Accounts.Studio
  alias AperDesk.Formats
  alias AperDesk.Money

  # A curated list rather than the full IANA set: a 400-entry dropdown is worse
  # than 30 that cover where photographers actually work, and the browser's own
  # zone is added on connect if it is missing.
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

  @impl true
  def mount(_params, _session, socket) do
    studio = socket.assigns.current_scope.studio

    {:ok,
     socket
     |> assign(page_title: "Set up your studio")
     |> assign(studio: studio)
     |> assign(time_zones: zones_including(studio.time_zone))
     |> assign(currencies: Money.supported_currencies())
     |> assign(form: to_form(Studio.setup_changeset(studio, %{}), as: :setup))
     |> assign(preview: preview(studio, %{}))
     |> assign(saving: false)}
  end

  @impl true
  def handle_event("detected-timezone", %{"time_zone" => zone}, socket) do
    # The browser knows where the visitor is; only trust it if it names a zone
    # we can actually resolve, and never overwrite a choice already made.
    if valid_zone?(zone) and socket.assigns.studio.time_zone in [nil, "Etc/UTC"] do
      params = Map.put(current_params(socket), "time_zone", zone)

      {:noreply,
       socket
       |> assign(time_zones: zones_including(zone))
       |> apply_params(params, validate?: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate", %{"setup" => params}, socket) do
    {:noreply, apply_params(socket, params)}
  end

  def handle_event("save", %{"setup" => params}, socket) do
    case Accounts.complete_setup(socket.assigns.current_scope, params) do
      {:ok, _studio} ->
        {:noreply,
         socket
         |> put_flash(:info, "Your studio is set up.")
         |> push_navigate(to: ~p"/app")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :setup))}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Only an owner can set the studio up. Ask yours to finish this."
         )}
    end
  end

  ## Internals

  # `validate?: false` leaves the changeset's action nil, so errors stay hidden.
  # Detecting the browser's time zone happens on mount, before the visitor has
  # typed anything — marking the form validated there would greet them with
  # "can't be blank" on every field they have not reached yet.
  defp apply_params(socket, params, opts \\ []) do
    changeset = Studio.setup_changeset(socket.assigns.studio, params)

    changeset =
      if Keyword.get(opts, :validate?, true),
        do: Map.put(changeset, :action, :validate),
        else: changeset

    socket
    |> assign(form: to_form(changeset, as: :setup))
    |> assign(preview: preview(socket.assigns.studio, params))
  end

  defp current_params(socket), do: socket.assigns.form.source.params || %{}

  # The example is rendered from a throwaway struct rather than the saved studio,
  # so it reflects what is currently selected rather than what was last saved.
  defp preview(studio, params) do
    Formats.sample(%Studio{
      studio
      | date_format: params["date_format"] || studio.date_format,
        time_format: params["time_format"] || studio.time_format,
        time_zone: params["time_zone"] || studio.time_zone
    })
  end

  defp zones_including(nil), do: @time_zones

  defp zones_including(zone) do
    if zone in @time_zones, do: @time_zones, else: Enum.sort([zone | @time_zones])
  end

  defp valid_zone?(zone) when is_binary(zone) do
    match?({:ok, _}, DateTime.now(zone))
  end

  defp valid_zone?(_zone), do: false

  @doc "How each date format reads, so the choice is not an abbreviation."
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
