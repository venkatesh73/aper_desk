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
  alias AperDesk.Directory

  @impl true
  def mount(%{"studio" => studio_slug, "form" => form_slug}, _session, socket) do
    case Comms.fetch_public_form(studio_slug, form_slug) do
      {:ok, form} ->
        {:ok,
         socket
         |> assign(page_title: form.headline || form.name)
         |> assign(form: form, fields: LeadCaptureForm.field_list(form))
         |> assign(answers: %{}, errors: %{}, sent: false)
         |> assign(hero: hero_for(form.studio_id))
         |> assign(caption: caption_for(form))
         # Read here because `get_connect_info/2` is only legal during mount,
         # and the submission that wants it happens later.
         |> assign(user_agent: connected?(socket) && get_connect_info(socket, :user_agent))
         |> assign(:page_layout, false)}

      {:error, :not_found} ->
        {:ok, assign(socket, form: nil, page_title: "Not found", sent: false)}
    end
  end

  # A chip is a radio the client can hit with a thumb. It writes into the same
  # answers map as every other field, so the submission path does not know the
  # difference.
  #
  # `phx-value-option`, not `phx-value-value`: for a button LiveView merges the
  # element's own `value` property into the params under "value", which
  # silently wins over the attribute and arrives as "". LiveViewTest reads the
  # attributes directly, so a test cannot see this — only a browser can.
  @impl true
  def handle_event("choose", %{"key" => key, "option" => value}, socket) do
    answers = socket.assigns.answers
    chosen = if Map.get(answers, key) == value, do: "", else: value

    {:noreply, assign(socket, answers: Map.put(answers, key, chosen))}
  end

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

  # The studio's own work, not a stock photograph. Their listing cover first,
  # then anything in their portfolio; a placeholder when they have neither,
  # which is better than a broken image on the page that collects their leads.
  defp hero_for(studio_id) do
    case Directory.list_portfolio(studio_id) do
      [%{url: url} | _rest] when is_binary(url) ->
        url

      _none ->
        case AperDesk.Repo.get_by(AperDesk.Directory.DirectoryListing, studio_id: studio_id) do
          %{cover_url: url} when is_binary(url) -> url
          _nothing -> nil
        end
    end
  end

  # The studio's own line about their work, not the form's title repeated over
  # the photograph next to it.
  defp caption_for(form) do
    case AperDesk.Repo.get_by(AperDesk.Directory.DirectoryListing, studio_id: form.studio_id) do
      %{headline: headline} when is_binary(headline) ->
        if headline == form.headline, do: nil, else: headline

      _none ->
        nil
    end
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

  @doc """
  Whether a choice field is short enough to be worth showing as chips.

  Six is where a row of chips stops fitting and starts wrapping into a wall.
  Above it the native picker wins — on a phone that is the OS wheel, which
  beats anything built out of divs.
  """
  def chips?(field) do
    input_type(field["type"]) == "select" and length(options_for(field)) in 2..6
  end

  @doc """
  Whether a field belongs in the two-column band.

  Names, emails, phone numbers and dates are short and read better side by
  side; anything someone writes a paragraph into does not.
  """
  def narrow?(field) do
    input_type(field["type"]) in ~w(text email tel date number) and not chips?(field)
  end

  @doc "Fields grouped into runs, so the short ones can share a row."
  def field_rows(fields) do
    fields
    |> Enum.chunk_by(&narrow?/1)
    |> Enum.map(fn group ->
      if narrow?(hd(group)), do: {:narrow, group}, else: {:wide, group}
    end)
  end
end
