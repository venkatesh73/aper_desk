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
  alias AperDeskWeb.StudioOptions

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

  defp zones_including(zone), do: StudioOptions.time_zones(zone)

  defp valid_zone?(zone) when is_binary(zone) do
    match?({:ok, _}, DateTime.now(zone))
  end

  defp valid_zone?(_zone), do: false

  @doc "How each date format reads, so the choice is not an abbreviation."
  defdelegate date_format_label(value), to: StudioOptions
  defdelegate time_format_label(value), to: StudioOptions
  defdelegate week_start_label(value), to: StudioOptions
  defdelegate sla_options, to: StudioOptions
end
