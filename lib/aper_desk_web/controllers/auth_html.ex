defmodule AperDeskWeb.AuthHTML do
  @moduledoc """
  Templates for sign-up and sign-in.

  Inputs are plain `<input>` elements rather than `CoreComponents.input/1`,
  because that component carries daisyUI classes and this application's styling
  comes from the ported design system, which styles bare form controls. Mixing
  the two produces a control with two competing sets of rules.
  """

  use AperDeskWeb, :html

  embed_templates "auth_html/*"

  @doc "Field errors from a changeset, rendered under the input."
  attr :form, :any, required: true
  attr :field, :atom, required: true

  def field_errors(assigns) do
    ~H"""
    <span :for={message <- errors_for(@form, @field)} class="fe">{message}</span>
    """
  end

  # Errors are shown only once the form has been submitted. A changeset built
  # for a blank form is already invalid — every required field is missing — so
  # rendering its errors greets a first-time visitor with "can't be blank" on
  # every input before they have typed anything. `action` is what distinguishes
  # "not filled in yet" from "tried and rejected".
  defp errors_for(%Ecto.Changeset{action: nil}, _field), do: []

  defp errors_for(form, field) do
    form.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end

  @doc "Marks an input invalid so the design system can style it."
  def invalid(form, field) do
    if errors_for(form, field) == [], do: nil, else: "invalid"
  end
end
