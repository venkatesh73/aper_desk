defmodule AperDeskWeb.TemplatesLive do
  @moduledoc """
  The three kinds of reusable document a studio writes once and sends often:
  email templates, contract templates, and the questionnaires it embeds on its
  own site.

  One screen with three tabs rather than three screens, because they are the
  same job — write it once, send it many times — and a photographer looking for
  "the thing I wrote" should not have to remember which menu it was under.

  Templates are archived, never deleted. A workflow step references a template
  by id, and deleting one leaves that step pointing at nothing — discovered at
  6am when the workflow fires.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Comms
  alias AperDesk.Comms.{EmailTemplate, LeadCaptureForm}
  alias AperDesk.Finance
  alias AperDesk.Finance.InvoiceTemplate
  alias AperDesk.Crm.Lead
  alias AperDesk.Formats
  alias AperDesk.Money
  alias AperDesk.Sales
  alias AperDesk.Sales.ContractTemplate
  alias AperDesk.Templating

  @tabs ~w(email contract questionnaire invoice)

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, tab: "email", preview: nil)}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "email"

    socket
    |> assign(page_title: "Templates", tab: tab)
    |> load_all()
  end

  defp apply_action(socket, :new, %{"kind" => kind}) when kind in @tabs do
    socket
    |> assign(page_title: "New #{label(kind)}")
    |> assign(kind: kind, record: nil)
    |> assign(questions: [])
    |> assign(form: blank_form(kind))
  end

  defp apply_action(socket, :edit, %{"kind" => kind, "id" => id}) when kind in @tabs do
    scope = socket.assigns.current_scope

    case fetch(scope, kind, id) do
      {:ok, record} ->
        socket
        |> assign(page_title: "Edit template")
        |> assign(kind: kind, record: record)
        |> assign(questions: questions_of(record))
        |> assign(form: to_form(changeset(kind, record), as: :template))

      {:error, _reason} ->
        socket
        |> put_flash(:error, "That template could not be found.")
        |> push_navigate(to: ~p"/app/templates")
    end
  end

  defp apply_action(socket, _action, _params) do
    push_navigate(socket, to: ~p"/app/templates")
  end

  @impl true
  def handle_event("switch-tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply, push_patch(socket, to: ~p"/app/templates?tab=#{tab}")}
  end

  def handle_event("validate", %{"template" => params}, socket) do
    socket = maybe_track_questions(socket, params)

    changeset =
      socket.assigns.kind
      |> changeset(socket.assigns.record, params |> with_questions(socket) |> with_tax_bps())
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :template))}
  end

  @doc false
  def handle_event("add-question", _params, socket) do
    next = %{
      "key" => suggest_key(socket.assigns.questions),
      "label" => "",
      "type" => "text",
      "required" => false,
      "placeholder" => "",
      "options" => ""
    }

    {:noreply, assign(socket, questions: socket.assigns.questions ++ [next])}
  end

  def handle_event("remove-question", %{"index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, assign(socket, questions: List.delete_at(socket.assigns.questions, index))}
  end

  # Moving a question changes the order the client is asked things in, which is
  # the one part of a form's design that is not visible from the field list
  # alone — so it is edited here rather than by retyping every label.
  def handle_event("move-question", %{"index" => index, "by" => by}, socket) do
    index = String.to_integer(index)
    target = index + String.to_integer(by)
    questions = socket.assigns.questions

    if target in 0..(length(questions) - 1) do
      moved = Enum.at(questions, index)

      reordered =
        questions
        |> List.delete_at(index)
        |> List.insert_at(target, moved)

      {:noreply, assign(socket, questions: reordered)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"template" => params}, socket) do
    scope = socket.assigns.current_scope
    kind = socket.assigns.kind
    socket = maybe_track_questions(socket, params)
    params = params |> with_questions(socket) |> with_tax_bps()

    result =
      case socket.assigns.record do
        nil -> create(scope, kind, params)
        record -> update(scope, kind, record.id, params)
      end

    case result do
      {:ok, _record} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{label(kind) |> String.capitalize()} saved.")
         |> push_navigate(to: ~p"/app/templates?tab=#{kind}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :template))}

      {:error, {:limit_reached, _key, used, limit}} ->
        {:noreply,
         put_flash(socket, :error, "Your plan allows #{limit} of these and you have #{used}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  @doc false
  def handle_event("preview", %{"kind" => kind, "id" => id}, socket) when kind in @tabs do
    case fetch(socket.assigns.current_scope, kind, id) do
      {:ok, record} -> {:noreply, assign(socket, preview: preview(socket, kind, record))}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "That template is not here.")}
    end
  end

  # Previewing what is on the form, before it is saved. This is the one that
  # earns its keep: the question a studio asks while writing is "does this read
  # right", and answering it should not require saving a half-finished draft.
  def handle_event("preview-draft", _params, socket) do
    kind = socket.assigns.kind

    record =
      kind
      |> changeset(socket.assigns.record, socket.assigns.form.params)
      |> Ecto.Changeset.apply_changes()

    {:noreply, assign(socket, preview: preview(socket, kind, record))}
  end

  def handle_event("close-preview", _params, socket), do: {:noreply, assign(socket, preview: nil)}

  def handle_event("archive", %{"kind" => kind, "id" => id}, socket) when kind in @tabs do
    scope = socket.assigns.current_scope

    result =
      case kind do
        "email" -> Comms.archive_template(scope, id)
        "contract" -> Sales.archive_template(scope, id)
        "questionnaire" -> Comms.update_form(scope, id, %{"active" => false})
        "invoice" -> Finance.archive_invoice_template(scope, id)
      end

    case result do
      {:ok, _record} ->
        {:noreply, socket |> put_flash(:info, "Archived.") |> load_all()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not archive: #{inspect(reason)}")}
    end
  end

  ## Data

  defp load_all(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(email_templates: Comms.list_templates(scope))
    |> assign(contract_templates: Sales.list_templates(scope))
    |> assign(forms: Comms.list_forms(scope))
    |> assign(invoice_templates: ok_or(Finance.list_invoice_templates(scope), []))
  end

  defp ok_or({:ok, value}, _fallback), do: value
  defp ok_or(_error, fallback), do: fallback

  defp fetch(scope, "email", id), do: Comms.fetch_template(scope, id)
  defp fetch(scope, "contract", id), do: Sales.fetch_template(scope, id)
  defp fetch(scope, "questionnaire", id), do: Comms.fetch_form(scope, id)
  defp fetch(scope, "invoice", id), do: Finance.fetch_invoice_template(scope, id)

  defp create(scope, "email", params), do: Comms.create_template(scope, params)
  defp create(scope, "contract", params), do: Sales.create_template(scope, params)
  defp create(scope, "questionnaire", params), do: Comms.create_form(scope, params)
  defp create(scope, "invoice", params), do: Finance.create_invoice_template(scope, params)

  defp update(scope, "email", id, params), do: Comms.update_template(scope, id, params)
  defp update(scope, "contract", id, params), do: Sales.update_template(scope, id, params)
  defp update(scope, "questionnaire", id, params), do: Comms.update_form(scope, id, params)

  defp update(scope, "invoice", id, params),
    do: Finance.update_invoice_template(scope, id, params)

  defp changeset(kind, record, params \\ %{})

  defp changeset("email", record, params),
    do: Comms.change_template(record || %EmailTemplate{}, params)

  defp changeset("contract", record, params),
    do: Sales.change_template(record || %ContractTemplate{}, params)

  defp changeset("questionnaire", record, params),
    do: Comms.change_form(record || %LeadCaptureForm{}, params)

  defp changeset("invoice", record, params),
    do: InvoiceTemplate.changeset(record || %InvoiceTemplate{}, params)

  defp blank_form(kind), do: to_form(changeset(kind, nil), as: :template)

  ## Questions

  # The questions live in a `:map` column rather than as rows, so they are
  # tracked in assigns and folded back into `fields` on the way to the
  # changeset. Reading them from the changeset instead would lose every edit
  # the moment a validation failed.
  defp questions_of(%LeadCaptureForm{} = form) do
    form
    |> LeadCaptureForm.field_list()
    |> Enum.map(fn field ->
      %{
        "key" => field["key"] || "",
        "label" => field["label"] || "",
        "type" => field["type"] || "text",
        "required" => field["required"] in [true, "true"],
        "placeholder" => field["placeholder"] || "",
        "options" => field |> Map.get("options", []) |> options_to_text()
      }
    end)
  end

  defp questions_of(_record), do: []

  defp options_to_text(options) when is_list(options), do: Enum.join(options, "\n")
  defp options_to_text(options) when is_binary(options), do: options
  defp options_to_text(_options), do: ""

  # What the browser posted wins over what we were holding, so typing into a
  # label survives the next keystroke's re-render.
  defp maybe_track_questions(socket, %{"questions" => posted}) when is_map(posted) do
    questions =
      posted
      |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
      |> Enum.map(fn {_index, question} ->
        %{
          "key" => question["key"] || "",
          "label" => question["label"] || "",
          "type" => question["type"] || "text",
          "required" => question["required"] in ["true", true, "on"],
          "placeholder" => question["placeholder"] || "",
          "options" => question["options"] || ""
        }
      end)

    assign(socket, questions: questions)
  end

  defp maybe_track_questions(socket, _params), do: socket

  defp with_questions(params, %{assigns: %{kind: "questionnaire", questions: questions}}) do
    fields =
      questions
      |> Enum.reject(&(String.trim(&1["label"]) == ""))
      |> Enum.map(fn question ->
        base = %{
          "key" => key_for(question),
          "label" => String.trim(question["label"]),
          "type" => question["type"],
          "required" => question["required"] == true
        }

        base
        |> put_unless_blank("placeholder", question["placeholder"])
        |> put_options(question)
      end)

    Map.put(params, "fields", %{"fields" => fields})
  end

  defp with_questions(params, _socket), do: params

  # A studio types 23, not 2300. The conversion happens once, here; everything
  # below this line is basis points, for the same reason money is integers.
  defp with_tax_bps(%{"tax_percent" => percent} = params) do
    bps =
      case Float.parse(to_string(percent)) do
        {value, _rest} -> round(value * 100)
        :error -> 0
      end

    Map.put(params, "tax_bps", bps)
  end

  defp with_tax_bps(params), do: params

  # A key is what a submission arrives under, so it has to be stable and
  # machine-safe. Derived from the label only when the author has not set one,
  # because renaming a question must not orphan the answers already collected
  # under the old key.
  defp key_for(%{"key" => key} = question) do
    case String.trim(key || "") do
      "" -> slugify(question["label"])
      existing -> existing
    end
  end

  defp slugify(label) do
    label
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> then(fn slug -> if slug == "", do: "question", else: slug end)
  end

  defp suggest_key(questions), do: "question_#{length(questions) + 1}"

  defp put_unless_blank(map, _key, value) when value in [nil, ""], do: map

  defp put_unless_blank(map, key, value) do
    case String.trim(value) do
      "" -> map
      trimmed -> Map.put(map, key, trimmed)
    end
  end

  defp put_options(map, %{"type" => "select"} = question) do
    options =
      question
      |> Map.get("options", "")
      |> to_string()
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if options == [], do: map, else: Map.put(map, "options", options)
  end

  defp put_options(map, _question), do: map

  ## Preview

  # Rendered against sample values rather than blanks. A preview full of empty
  # strings shows a layout the studio never actually sends — the gaps close up
  # and the message reads shorter than it will — and one left as literal
  # `{{first_name}}` does not answer the question either.
  defp preview(socket, "email", %EmailTemplate{} = template) do
    assigns = Templating.sample_assigns(socket.assigns.current_scope)
    rendered = EmailTemplate.render(template, assigns)

    %{
      kind: "email",
      title: template.name || "Untitled template",
      subject: rendered.subject,
      body: rendered.body,
      to: assigns["name"] <> " <" <> assigns["email"] <> ">",
      from: assigns["studio_name"]
    }
  end

  defp preview(socket, "contract", %ContractTemplate{} = template) do
    assigns = Templating.sample_assigns(socket.assigns.current_scope)

    %{
      kind: "contract",
      title: template.name || "Untitled contract",
      body: ContractTemplate.render(template, assigns),
      requires_deposit: template.requires_deposit,
      client: assigns["name"],
      studio: assigns["studio_name"],
      deposit: assigns["deposit"]
    }
  end

  defp preview(socket, "invoice", %InvoiceTemplate{} = template) do
    scope = socket.assigns.current_scope
    today = Formats.today_for(scope)
    subtotal = 450_000

    %{
      kind: "invoice",
      title: template.name || "Untitled template",
      client: "Anna Bell",
      studio: (scope.studio && scope.studio.name) || "Your studio",
      issued_on: Formats.date(scope, today),
      due_on: Formats.date(scope, Date.add(today, template.due_in_days || 0)),
      due_in_days: template.due_in_days || 0,
      subtotal: money(scope, subtotal),
      tax_label: template.tax_label || "Tax",
      tax_percent: InvoiceTemplate.tax_percent(template),
      tax: money(scope, InvoiceTemplate.tax_on(template, subtotal, scope.currency)),
      total: money(scope, subtotal + InvoiceTemplate.tax_on(template, subtotal, scope.currency)),
      deposit_percent: template.deposit_percent,
      notes: template.notes,
      payment_instructions: template.payment_instructions
    }
  end

  defp preview(_socket, "questionnaire", %LeadCaptureForm{} = form) do
    %{
      kind: "questionnaire",
      title: form.name || "Untitled questionnaire",
      headline: form.headline,
      intro: form.intro,
      fields: LeadCaptureForm.field_list(form),
      success_message: form.success_message
    }
  end

  ## Presentation

  def tabs, do: @tabs

  def label("email"), do: "email template"
  def label("contract"), do: "contract template"
  def label("questionnaire"), do: "questionnaire"
  def label("invoice"), do: "invoice template"

  def tab_label("email"), do: "Email"
  def tab_label("contract"), do: "Contracts"
  def tab_label("questionnaire"), do: "Questionnaires"
  def tab_label("invoice"), do: "Invoices"

  def shoot_types, do: ["" | Lead.shoot_types()]

  def humanise(""), do: "Any shoot type"
  def humanise(nil), do: "Any shoot type"
  def humanise(value), do: value |> String.replace("_", " ") |> String.capitalize()

  @doc """
  The placeholders a template may use.

  Listed on the form rather than documented elsewhere, because a token nobody
  can remember is a token nobody uses — and an unknown one renders as literal
  `{{whatever}}` in a client's inbox.
  """
  def tokens, do: Templating.tokens()

  defp money(scope, cents),
    do: cents |> Money.new(scope.currency) |> Money.to_string()

  @doc "The kinds an invoice template can be raised as."
  def invoice_kinds,
    do:
      Enum.map(AperDesk.Finance.Invoice.kinds(), fn kind ->
        {kind |> String.replace("_", " ") |> String.capitalize(), kind}
      end)

  @doc "A tax rate in basis points, shown and typed as a percentage."
  def tax_percent_value(%InvoiceTemplate{tax_bps: bps}) when is_integer(bps), do: bps / 100
  def tax_percent_value(_template), do: 0

  @doc "Whether this template fills the due date in from a count of days."
  def due_line(%InvoiceTemplate{due_in_days: 0}), do: "Due the day it is issued"
  def due_line(%InvoiceTemplate{due_in_days: 1}), do: "Due the next day"
  def due_line(%InvoiceTemplate{due_in_days: days}), do: "Due #{days} days after issue"

  @doc "The question types a form may ask, as the author would name them."
  def question_types do
    [
      {"Short text", "text"},
      {"Long text", "textarea"},
      {"Email", "email"},
      {"Phone", "phone"},
      {"Date", "date"},
      {"A choice", "select"},
      {"Yes or no", "checkbox"},
      {"Number", "number"}
    ]
  end

  @doc "Whether this type needs a list of choices spelling out."
  def needs_options?("select"), do: true
  def needs_options?(_type), do: false

  @doc "A questionnaire field's input type, mapped to what the browser calls it."
  def input_type("textarea"), do: "textarea"
  def input_type("email"), do: "email"
  def input_type("phone"), do: "tel"
  def input_type("date"), do: "date"
  def input_type("number"), do: "number"
  def input_type("checkbox"), do: "checkbox"
  def input_type("select"), do: "select"
  def input_type(_text), do: "text"

  @doc "The choices a select field offers, however they were written."
  def field_options(%{"options" => options}) when is_list(options), do: options

  def field_options(%{"options" => options}) when is_binary(options),
    do: options |> String.split(~r/[\n,]/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  def field_options(_field), do: []

  def active?(%LeadCaptureForm{active: active}), do: active
  def active?(%{archived_at: nil}), do: true
  def active?(_record), do: false
end
