defmodule AperDeskWeb.PublicFormLive do
  @moduledoc """
  The form a studio embeds on its own site, as the client fills it in.

  The Questionnaires tab has shown `/f/<slug>` as the link since it was built
  and nothing served it, so every questionnaire a studio wrote pointed at a
  404. This is the front of the whole funnel — a lead that never arrives cannot
  be quoted, booked, shot or invoiced.

  No session, no studio scope, and no authorisation: it is a public page by
  definition. What protects it is that `submit_form/3` validates against the
  form's own field definitions and drops anything it does not recognise, so the
  worst a hostile submission can do is fail.

  The answers are kept raw alongside the lead they created, so a bad mapping
  can be diagnosed against what the client actually typed rather than against
  what the studio's field definitions claim they typed.
  """

  use AperDeskWeb, :live_view

  alias AperDesk.Comms
  alias AperDesk.Comms.LeadCaptureForm

  @impl true
  def mount(%{"studio" => studio_slug, "form" => form_slug}, _session, socket) do
    case Comms.fetch_public_form(studio_slug, form_slug) do
      {:ok, form} ->
        {:ok,
         socket
         |> assign(page_title: form.headline || form.name)
         |> assign(form: form, fields: LeadCaptureForm.field_list(form))
         |> assign(answers: %{}, errors: %{}, sent: false)
         # Read here because `get_connect_info/2` is only legal during mount,
         # and the submission that wants it happens later.
         |> assign(user_agent: connected?(socket) && get_connect_info(socket, :user_agent))
         |> assign(:page_layout, false)}

      {:error, :not_found} ->
        {:ok, assign(socket, form: nil, page_title: "Not found", sent: false)}
    end
  end

  @impl true
  def handle_event("validate", %{"answers" => answers}, socket) do
    {:noreply, assign(socket, answers: answers)}
  end

  def handle_event("submit", %{"answers" => answers}, socket) do
    form = socket.assigns.form

    case Comms.submit_form(form, answers, meta(socket)) do
      {:ok, _result} ->
        {:noreply, assign(socket, sent: true, answers: %{}, errors: %{})}

      {:error, errors} when is_list(errors) ->
        # The form's own required-field rules, reported against the field the
        # client can see rather than as one banner they have to decode.
        {:noreply, assign(socket, answers: answers, errors: Map.new(errors))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(answers: answers)
         |> put_flash(:error, "That did not send. Try once more, or email us directly.")}
    end
  end

  # Kept with the submission so a studio can tell a genuine enquiry from a bot
  # filling every form on the internet, without having to guess from the text.
  defp meta(socket) do
    %{
      "user_agent" => socket.assigns[:user_agent],
      "submitted_at" => DateTime.utc_now()
    }
  end

  ## Presentation

  def input_type("textarea"), do: "textarea"
  def input_type("email"), do: "email"
  def input_type("phone"), do: "tel"
  def input_type("date"), do: "date"
  def input_type("number"), do: "number"
  def input_type("checkbox"), do: "checkbox"
  def input_type("select"), do: "select"
  def input_type(_text), do: "text"

  def options_for(%{"options" => options}) when is_list(options), do: options
  def options_for(_field), do: []

  def required?(%{"required" => required}), do: required in [true, "true"]
  def required?(_field), do: false

  def error_for(errors, %{"key" => key}), do: Map.get(errors, key)
  def error_for(_errors, _field), do: nil

  def value_for(answers, %{"key" => key}), do: Map.get(answers, key, "")
  def value_for(_answers, _field), do: ""
end
