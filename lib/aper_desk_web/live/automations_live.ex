defmodule AperDeskWeb.AutomationsLive do
  @moduledoc """
  Workflows, nurture sequences, and everything waiting on a person.

  The approvals queue comes first on purpose. "Automations should be obvious,
  not magic" is only true if what is about to go out in the studio's name is the
  first thing they see, showing the actual message rather than a description of
  one.

  Every workflow states what fires it and what it does. A rule whose behaviour
  cannot be read off the screen is one nobody will trust enough to switch on.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Automation
  alias AperDesk.Automation.{NurtureSequence, Workflow}
  alias AperDesk.Comms
  alias AperDesk.Crm.Lead
  alias AperDeskWeb.Graphql.Resolvers.Helpers

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, tab: "workflows")}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    tab =
      if params["tab"] in ~w(workflows nurture approvals), do: params["tab"], else: "workflows"

    socket
    |> assign(page_title: "Automations", tab: tab)
    |> load_all()
  end

  defp apply_action(socket, :new_workflow, _params) do
    socket
    |> assign(page_title: "New workflow", kind: :workflow, record: nil)
    |> assign(templates: Comms.list_templates(socket.assigns.current_scope))
    # The first step's fields are not part of the Workflow changeset, so they
    # are tracked separately. Rendering them from the changeset dropped the
    # chosen template on every keystroke.
    |> assign(step: %{"template_id" => "", "delay_minutes" => "0"})
    |> assign(form: to_form(Automation.change_workflow(), as: :workflow))
  end

  defp apply_action(socket, :new_sequence, _params) do
    socket
    |> assign(page_title: "New nurture sequence", kind: :sequence, record: nil)
    |> assign(form: to_form(Automation.change_sequence(), as: :sequence))
  end

  defp apply_action(socket, :edit_sequence, %{"id" => id}) do
    case Automation.fetch_sequence(socket.assigns.current_scope, id) do
      {:ok, sequence} ->
        socket
        |> assign(page_title: "Edit #{sequence.name}", kind: :sequence, record: sequence)
        |> assign(form: to_form(Automation.change_sequence(sequence), as: :sequence))

      {:error, _reason} ->
        socket
        |> put_flash(:error, "That sequence could not be found.")
        |> push_navigate(to: ~p"/app/automations?tab=nurture")
    end
  end

  @impl true
  def handle_event("switch-tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/app/automations?tab=#{tab}")}
  end

  def handle_event("toggle-workflow", %{"id" => id, "active" => active}, socket) do
    case Automation.update_workflow(socket.assigns.current_scope, id, %{"active" => active}) do
      {:ok, workflow} ->
        state = if workflow.active, do: "switched on", else: "switched off"
        {:noreply, socket |> put_flash(:info, "#{workflow.name} #{state}.") |> load_all()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, "A workflow needs at least one step before it can run.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not change that: #{inspect(reason)}")}
    end
  end

  def handle_event("set-mode", %{"id" => id, "mode" => mode}, socket) do
    case Automation.update_workflow(socket.assigns.current_scope, id, %{"approval_mode" => mode}) do
      {:ok, _workflow} ->
        {:noreply, socket |> put_flash(:info, "Approval mode changed.") |> load_all()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not change that: #{inspect(reason)}")}
    end
  end

  def handle_event("approve", %{"id" => id}, socket) do
    case Automation.approve_step(socket.assigns.current_scope, id) do
      {:ok, _step} -> {:noreply, socket |> put_flash(:info, "Approved.") |> load_all()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, describe(reason))}
    end
  end

  def handle_event("reject", %{"id" => id}, socket) do
    case Automation.reject_step(socket.assigns.current_scope, id) do
      {:ok, _step} ->
        {:noreply,
         socket |> put_flash(:info, "Rejected, and the run was cancelled.") |> load_all()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, describe(reason))}
    end
  end

  def handle_event("validate", %{"workflow" => params}, socket) do
    changeset = Automation.change_workflow(%Workflow{}, params) |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(form: to_form(changeset, as: :workflow))
     |> assign(step: step_params(socket.assigns.step, params))}
  end

  def handle_event("validate", %{"sequence" => params}, socket) do
    base = socket.assigns.record || %NurtureSequence{}
    changeset = Automation.change_sequence(base, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset, as: :sequence))}
  end

  def handle_event("save", %{"workflow" => params}, socket) do
    step = step_params(socket.assigns.step, params)

    if step["template_id"] in [nil, ""] do
      {:noreply, put_flash(socket, :error, "Choose the template this workflow should send.")}
    else
      save_workflow(socket, params, step)
    end
  end

  def handle_event("save", %{"sequence" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.record do
        nil -> Automation.create_sequence(scope, params)
        record -> Automation.update_sequence(scope, record.id, params)
      end

    case result do
      {:ok, _sequence} ->
        {:noreply,
         socket
         |> put_flash(:info, "Sequence saved.")
         |> push_navigate(to: ~p"/app/automations?tab=nurture")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :sequence))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  defp save_workflow(socket, params, step) do
    case Automation.create_workflow(socket.assigns.current_scope, with_step(params, step)) do
      {:ok, _workflow} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workflow created. It stays off until you switch it on.")
         |> push_navigate(to: ~p"/app/automations")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :workflow))}

      {:error, {:limit_reached, _key, used, limit}} ->
        {:noreply,
         put_flash(socket, :error, "Your plan allows #{limit} workflows and you have #{used}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  ## Data

  defp load_all(socket) do
    scope = socket.assigns.current_scope

    workflows =
      case Automation.list_workflows(scope) do
        {:ok, list} -> list
        _ -> []
      end

    socket
    |> assign(workflows: workflows)
    |> assign(sequences: Automation.list_sequences(scope))
    |> assign(approvals: Automation.awaiting_approval(scope))
  end

  # Carries the step fields across re-renders. They are not Workflow attributes,
  # so the changeset cannot hold them and the form would otherwise reset the
  # chosen template every time another field changed.
  defp step_params(current, params) do
    Enum.reduce(["template_id", "delay_minutes"], current, fn key, acc ->
      case Map.get(params, key) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # A workflow with no steps is refused when active, and useless when not, so
  # the form collects its first step rather than making that a second trip.
  defp with_step(params, step) do
    first_step = %{
      "name" => "Send template",
      "action" => "send_template",
      "config" => %{"template_id" => step["template_id"]},
      "delay_minutes" => step["delay_minutes"] || "0",
      "position" => 0
    }

    params
    |> Map.drop(["template_id", "delay_minutes"])
    |> Map.put("steps", [first_step])
  end

  defp describe(:unauthorized), do: "You do not have permission to do that."
  defp describe(:not_found), do: "That step could not be found."
  defp describe(other), do: "Something went wrong: #{inspect(other)}"

  ## Presentation

  def trigger_events, do: Workflow.trigger_events()

  def humanise(nil), do: "Any"
  def humanise(""), do: "Any"

  def humanise(value),
    do: value |> to_string() |> String.replace(["_", "."], " ") |> String.capitalize()

  def stages, do: ["" | Lead.stages()]

  def mode_label("auto"), do: "Runs on its own"
  def mode_label("ask"), do: "Asks you first"

  def time_ago(at), do: Helpers.time_ago(at)

  @doc "What a parked step would actually send, as stored on the run step."
  def preview_line(%{preview: preview}) when is_map(preview) do
    subject = preview["subject"]
    body = preview["body"]

    cond do
      subject && body -> "#{subject} — #{String.slice(body, 0, 90)}"
      subject -> subject
      body -> String.slice(body, 0, 120)
      true -> "No preview was recorded for this step."
    end
  end

  def preview_line(_step), do: "No preview was recorded for this step."
end
