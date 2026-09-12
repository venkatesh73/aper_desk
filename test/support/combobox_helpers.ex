defmodule AperDeskWeb.ComboboxHelpers do
  @moduledoc """
  Driving `AperDeskWeb.Combobox` from a test.

  A combobox writes to a hidden input, and `LiveViewTest` deliberately refuses
  to set hidden inputs — they are not user-editable, and letting a test set one
  would let it assert a state a person cannot reach. So tests open the picker
  and click an option, which is what a person does.
  """

  import Phoenix.LiveViewTest

  @doc """
  Open `combo_id` and choose the option whose text matches `label`.

  Returns the rendered result, so a caller can assert on what the choice
  changed without a second round trip.
  """
  def choose(view, combo_id, label) do
    view |> element("##{combo_id} .combo-button") |> render_click()
    view |> element("##{combo_id} .combo-option", label) |> render_click()
  end

  @doc "Type into an open combobox's search box."
  def combo_search(view, combo_id, query) do
    view |> element("##{combo_id}-search") |> render_keyup(%{"value" => query})
  end

  @doc "Open a combobox without choosing anything."
  def open_combo(view, combo_id) do
    view |> element("##{combo_id} .combo-button") |> render_click()
  end

  @doc """
  Choose an option and wait for the parent LiveView to act on it.

  A combobox wired with `on_select` messages its parent, and the parent's
  `handle_info/2` runs after the click has already returned — so anything the
  parent does in response is not in the click's own render. `render/1` here is
  what makes the result visible, and a test asserting on the click's return
  value alone would miss it.
  """
  def choose_and_settle(view, combo_id, label) do
    choose(view, combo_id, label)
    render(view)
  end
end
