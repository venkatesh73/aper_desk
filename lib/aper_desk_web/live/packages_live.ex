defmodule AperDeskWeb.PackagesLive do
  @moduledoc """
  What the studio sells: name, price, what is included, how long it takes.

  Packages are archived, never deleted. A quote issued last month names the
  package it was built from, and deleting the row would turn that quote's
  provenance into a dangling id.

  Prices are entered in major units and converted here, because nobody types
  450000 for four and a half thousand. The conversion happens once, at this
  boundary; everything below it is integer minor units.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Catalog
  alias AperDesk.Catalog.Package
  alias AperDesk.Crm.Lead
  alias AperDesk.Money

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, show_archived: false)}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: "Packages")
    |> load_packages()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "New package")
    |> assign(package: %Package{})
    # Tracked separately: price is typed in major units, which is not a schema
    # field. Rendering it from the struct reset the box on every keystroke, so
    # the package saved with no price at all.
    |> assign(price_major: nil)
    |> assign(form: to_form(Catalog.change_package(), as: :package))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Catalog.fetch_package(socket.assigns.current_scope, id) do
      {:ok, package} ->
        socket
        |> assign(page_title: "Edit #{package.name}")
        |> assign(package: package)
        |> assign(price_major: price_major(package))
        |> assign(form: to_form(Catalog.change_package(package), as: :package))

      {:error, _reason} ->
        socket
        |> put_flash(:error, "That package could not be found.")
        |> push_navigate(to: ~p"/app/packages")
    end
  end

  @impl true
  def handle_event("toggle-archived", _params, socket) do
    {:noreply,
     socket |> assign(show_archived: not socket.assigns.show_archived) |> load_packages()}
  end

  def handle_event("validate", %{"package" => params}, socket) do
    changeset =
      socket.assigns.package
      |> Catalog.change_package(to_cents(params, socket.assigns.current_scope))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(form: to_form(changeset, as: :package))
     |> assign(price_major: params["price_major"] || socket.assigns.price_major)}
  end

  def handle_event("save", %{"package" => params}, socket) do
    scope = socket.assigns.current_scope
    params = Map.put_new(params, "price_major", socket.assigns.price_major)
    attrs = to_cents(params, scope)

    result =
      case socket.assigns.live_action do
        :new -> Catalog.create_package(scope, attrs)
        :edit -> Catalog.update_package(scope, socket.assigns.package.id, attrs)
      end

    case result do
      {:ok, _package} ->
        {:noreply,
         socket
         |> put_flash(:info, "Package saved.")
         |> push_navigate(to: ~p"/app/packages")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :package))}

      {:error, {:limit_reached, _key, used, limit}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Your plan allows #{limit} packages and you have #{used}. Archive one or move up a plan."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    case Catalog.archive_package(socket.assigns.current_scope, id) do
      {:ok, package} ->
        {:noreply, socket |> put_flash(:info, "#{package.name} archived.") |> load_packages()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not archive: #{inspect(reason)}")}
    end
  end

  def handle_event("restore", %{"id" => id}, socket) do
    case Catalog.restore_package(socket.assigns.current_scope, id) do
      {:ok, package} ->
        {:noreply, socket |> put_flash(:info, "#{package.name} restored.") |> load_packages()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not restore: #{inspect(reason)}")}
    end
  end

  ## Internals

  defp load_packages(socket) do
    packages =
      Catalog.list_packages(socket.assigns.current_scope,
        include_archived: socket.assigns.show_archived
      )

    assign(socket, packages: packages)
  end

  # Prices are typed in major units. The conversion happens once, here, and
  # everything below this line is integer minor units — see `AperDesk.Money`.
  defp to_cents(params, scope) do
    currency = params["price_currency"] || scope.currency

    case params["price_major"] do
      nil ->
        params

      "" ->
        Map.put(params, "price_cents", 0)

      major ->
        params
        |> Map.put("price_cents", Money.from_major(major, currency))
        |> Map.put("price_currency", currency)
    end
  end

  ## Presentation

  def shoot_types, do: Lead.shoot_types()

  def humanise(value), do: value |> String.replace("_", " ") |> String.capitalize()

  def price(package), do: package |> Package.price() |> Money.to_string()

  def deposit(package), do: package |> Package.deposit() |> Money.to_string()

  @doc "The price in major units, for the form field."
  def price_major(%Package{price_cents: nil}), do: nil

  def price_major(%Package{price_cents: cents, price_currency: currency}),
    do: Money.to_major(cents, currency || "USD")

  def duration(%Package{duration_minutes: nil}), do: "—"
  def duration(%Package{duration_minutes: minutes}) when minutes < 60, do: "#{minutes} min"

  def duration(%Package{duration_minutes: minutes}) do
    hours = div(minutes, 60)
    rest = rem(minutes, 60)
    if rest == 0, do: "#{hours} h", else: "#{hours} h #{rest} min"
  end
end
