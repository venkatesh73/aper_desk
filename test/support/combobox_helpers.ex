defmodule AperDeskWeb.ComboboxHelpers do
  @moduledoc """
  Driving `AperDeskWeb.Combobox` from a test.

  A combobox writes to a hidden input, and `LiveViewTest` deliberately refuses
  to set hidden inputs — they are not user-editable, and letting a test set one
  would let it assert a state a person cannot reach. So tests open the picker
  and click an option, which is what a person does.
  """

  import Phoenix.LiveViewTest

  @doc "Open `combo_id` and choose the option whose text matches `label`."
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
end
