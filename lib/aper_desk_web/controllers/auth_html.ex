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

  @doc """
  The "continue with Google" button, and the rule separating it from the form.

  Renders nothing at all when Google sign-in is unconfigured. A button that
  leads to Google's own error page is worse than no button: it looks like the
  product is broken rather than like the feature is off.
  """
  attr :action, :string, default: "Continue"

  def google_button(assigns) do
    assigns = assign(assigns, :configured?, AperDesk.Accounts.Google.configured?())

    ~H"""
    <div :if={@configured?}>
      <a class="btn oauth" href={~p"/auth/google"}>
        <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
          <path
            fill="#4285F4"
            d="M23 12.3c0-.8-.1-1.6-.2-2.3H12v4.5h6.2a5.3 5.3 0 0 1-2.3 3.5v2.9h3.7c2.2-2 3.4-5 3.4-8.6z"
          />
          <path
            fill="#34A853"
            d="M12 24c3.1 0 5.7-1 7.6-2.8l-3.7-2.9c-1 .7-2.3 1.1-3.9 1.1-3 0-5.5-2-6.4-4.7H1.8v3C3.7 21.4 7.6 24 12 24z"
          />
          <path fill="#FBBC05" d="M5.6 14.7a7.2 7.2 0 0 1 0-4.6v-3H1.8a12 12 0 0 0 0 10.6l3.8-3z" />
          <path
            fill="#EA4335"
            d="M12 4.8c1.7 0 3.2.6 4.4 1.7l3.3-3.3A11.5 11.5 0 0 0 12 0C7.6 0 3.7 2.6 1.8 6.1l3.8 3C6.5 6.7 9 4.8 12 4.8z"
          />
        </svg>
        {@action} with Google
      </a>

      <div class="orline"><span>or</span></div>
    </div>
    """
  end

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
