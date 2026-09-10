defmodule AperDeskWeb.Combobox do
  @moduledoc """
  A select you can search.

  A native `<select>` cannot be filtered, and a studio with four hundred
  contacts cannot scroll to the right one — which is exactly the list this is
  usually pointed at.

  It writes to a hidden input, so it behaves like any other form control: the
  surrounding `<.form>` submits it, changesets validate it, and nothing outside
  this module needs to know it is not a `<select>`.

  Filtering happens on the server. That sounds heavier than filtering in the
  browser and is not: the list is already on the server, the round trip is a
  LiveView diff of a few rows, and it means the same component works unchanged
  when the options come from a query rather than an array.

  Keyboard: type to filter, up and down to move, Enter to choose, Escape to
  close. Handled with LiveView's own key bindings rather than a JS hook, so
  there is one implementation rather than two.

  ## Example

      <.live_component
        module={AperDeskWeb.Combobox}
        id="lead-contact"
        name="lead[contact_id]"
        value={@form[:contact_id].value}
        options={Enum.map(@contacts, &{&1.name, &1.id, &1.email})}
        prompt="Not linked to a contact yet"
      />
  """

  use AperDeskWeb, :live_component

  @doc false
  @impl true
  def mount(socket) do
    {:ok, assign(socket, open: false, query: "", active: 0)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:prompt, fn -> "Choose one" end)
     |> assign_new(:search_placeholder, fn -> "Type to search" end)
     |> assign_new(:empty_message, fn -> "Nothing matched" end)
     |> assign_new(:allow_clear, fn -> true end)
     |> assign_new(:required, fn -> false end)
     |> normalise_options()}
  end

  @impl true
  def handle_event("open", _params, socket) do
    {:noreply, assign(socket, open: true, query: "", active: 0)}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, open: false, query: "")}
  end

  def handle_event("search", %{"value" => query}, socket) do
    {:noreply, assign(socket, query: query, active: 0)}
  end

  def handle_event("select", %{"value" => value}, socket) do
    {:noreply,
     socket
     |> assign(value: value, open: false, query: "")
     |> notify_parent(value)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(value: nil, open: false, query: "")
     |> notify_parent(nil)}
  end

  # Receives every keydown in the search box. Only the navigation keys act; the
  # rest fall through so typing still reaches `search`.
  def handle_event("move", %{"key" => key}, socket) do
    matches = filtered(socket.assigns)
    count = length(matches)

    cond do
      count == 0 ->
        {:noreply, socket}

      key == "ArrowDown" ->
        {:noreply, assign(socket, active: rem(socket.assigns.active + 1, count))}

      key == "ArrowUp" ->
        {:noreply, assign(socket, active: rem(socket.assigns.active - 1 + count, count))}

      key == "Enter" ->
        case Enum.at(matches, socket.assigns.active) do
          nil -> {:noreply, socket}
          option -> handle_event("select", %{"value" => option.value}, socket)
        end

      key == "Escape" ->
        {:noreply, assign(socket, open: false, query: "")}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:matches, filtered(assigns))
      |> assign(:selected, selected(assigns))

    ~H"""
    <div
      class="combo"
      id={@id}
      data-combo
      phx-click-away={@open && JS.push("close", target: @myself)}
    >
      <input type="hidden" name={@name} value={@value || ""} />

      <button
        type="button"
        class="combo-button"
        aria-expanded={to_string(@open)}
        aria-haspopup="listbox"
        phx-click={JS.push("open", target: @myself) |> JS.focus(to: "##{@id}-search")}
      >
        <span class={["combo-value", is_nil(@selected) && "placeholder"]}>
          {(@selected && @selected.label) || @prompt}
        </span>
        <svg class="combo-caret" viewBox="0 0 24 24" aria-hidden="true">
          <path d="m6 9 6 6 6-6" />
        </svg>
      </button>

      <div :if={@open} class="combo-panel" role="listbox">
        <div class="combo-search">
          <input
            type="text"
            id={"#{@id}-search"}
            value={@query}
            placeholder={@search_placeholder}
            autocomplete="off"
            phx-keyup="search"
            phx-target={@myself}
            phx-debounce="60"
            phx-hook="ComboSearch"
          />
        </div>

        <div class="combo-list">
          <button
            :for={{option, index} <- Enum.with_index(@matches)}
            type="button"
            class="combo-option"
            role="option"
            data-active={to_string(index == @active)}
            aria-selected={to_string(option.value == @value)}
            phx-click={JS.push("select", value: %{value: option.value}, target: @myself)}
          >
            <span>{option.label}</span>
            <span :if={option.detail} class="combo-sub">{option.detail}</span>
          </button>

          <div :if={@matches == []} class="combo-empty">{@empty_message}</div>
        </div>

        <button
          :if={@allow_clear and not is_nil(@value) and @value != ""}
          type="button"
          class="combo-clear"
          phx-click={JS.push("clear", target: @myself)}
        >
          Clear selection
        </button>
      </div>
    </div>
    """
  end

  ## Internals

  # Options arrive as {label, value}, {label, value, detail} or a map. They are
  # normalised once here so the template only ever deals with one shape.
  defp normalise_options(socket) do
    options =
      socket.assigns
      |> Map.get(:options, [])
      |> Enum.map(fn
        %{label: _label, value: _value} = option -> Map.put_new(option, :detail, nil)
        {label, value} -> %{label: label, value: to_string(value), detail: nil}
        {label, value, detail} -> %{label: label, value: to_string(value), detail: detail}
        value -> %{label: to_string(value), value: to_string(value), detail: nil}
      end)
      |> Enum.map(&%{&1 | value: to_string(&1.value)})

    assign(socket, options: options)
  end

  defp filtered(%{options: options, query: query}) when query in [nil, ""], do: options

  defp filtered(%{options: options, query: query}) do
    needle = String.downcase(query)

    Enum.filter(options, fn option ->
      String.contains?(String.downcase(option.label), needle) or
        (option.detail && String.contains?(String.downcase(to_string(option.detail)), needle))
    end)
  end

  defp filtered(_assigns), do: []

  defp selected(%{options: options, value: value}) when not is_nil(value) and value != "" do
    Enum.find(options, &(&1.value == to_string(value)))
  end

  defp selected(_assigns), do: nil

  # Tells the parent LiveView the value changed, so a form relying on
  # `phx-change` still sees it — a hidden input's value does not trigger one.
  defp notify_parent(socket, value) do
    case socket.assigns[:on_select] do
      nil -> socket
      event when is_binary(event) -> push_event(socket, event, %{value: value})
      _ -> socket
    end
  end
end
