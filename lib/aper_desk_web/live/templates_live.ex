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
  alias AperDesk.Crm.Lead
  alias AperDesk.Sales
  alias AperDesk.Sales.ContractTemplate
  alias AperDesk.Templating

  @tabs ~w(email contract questionnaire)

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
    |> assign(form: blank_form(kind))
  end

  defp apply_action(socket, :edit, %{"kind" => kind, "id" => id}) when kind in @tabs do
    scope = socket.assigns.current_scope

    case fetch(scope, kind, id) do
      {:ok, record} ->
        socket
        |> assign(page_title: "Edit template")
        |> assign(kind: kind, record: record)
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
    changeset =
      socket.assigns.kind
      |> changeset(socket.assigns.record, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :template))}
  end

  def handle_event("save", %{"template" => params}, socket) do
    scope = socket.assigns.current_scope
    kind = socket.assigns.kind

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
  end

  defp fetch(scope, "email", id), do: Comms.fetch_template(scope, id)
  defp fetch(scope, "contract", id), do: Sales.fetch_template(scope, id)
  defp fetch(scope, "questionnaire", id), do: Comms.fetch_form(scope, id)

  defp create(scope, "email", params), do: Comms.create_template(scope, params)
  defp create(scope, "contract", params), do: Sales.create_template(scope, params)
  defp create(scope, "questionnaire", params), do: Comms.create_form(scope, params)

  defp update(scope, "email", id, params), do: Comms.update_template(scope, id, params)
  defp update(scope, "contract", id, params), do: Sales.update_template(scope, id, params)
  defp update(scope, "questionnaire", id, params), do: Comms.update_form(scope, id, params)

  defp changeset(kind, record, params \\ %{})

  defp changeset("email", record, params),
    do: Comms.change_template(record || %EmailTemplate{}, params)

  defp changeset("contract", record, params),
    do: Sales.change_template(record || %ContractTemplate{}, params)

  defp changeset("questionnaire", record, params),
    do: Comms.change_form(record || %LeadCaptureForm{}, params)

  defp blank_form(kind), do: to_form(changeset(kind, nil), as: :template)

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

  def tab_label("email"), do: "Email"
  def tab_label("contract"), do: "Contracts"
  def tab_label("questionnaire"), do: "Questionnaires"

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
