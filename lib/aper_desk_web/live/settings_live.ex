defmodule AperDeskWeb.SettingsLive do
  @moduledoc """
  Everything the studio decides about itself, in one place with a section nav.

  Each section saves on its own. One giant form with a single Save button reads
  tidier and behaves worse: a validation error in the billing section would
  block a change to the studio's phone number, and nobody would guess why.

  Two things here are deliberately read-only. The permission matrix is drawn
  from `AperDesk.Authorization` rather than from a copy, because a hand-written
  table is wrong the first time a permission moves and nobody notices until
  someone cannot open a screen they should. And the plan's limits come from the
  `Plan` row, so what the studio is told it has bought is what the quota checks
  actually enforce.

  The sections a person may see follow from their role — a photographer has no
  business in billing — and the nav is filtered rather than the panels being
  shown and then refusing to work.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Accounts
  alias AperDesk.Accounts.{Studio, User}
  alias AperDesk.Authorization
  alias AperDesk.Billing
  alias AperDesk.Formats
  alias AperDesk.Money
  alias AperDeskWeb.StudioOptions

  @sections ~w(studio formats account roles plan)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Settings")
     |> assign(password_form: to_form(%{}, as: :password))
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    section = if params["section"] in visible_sections(socket), do: params["section"], else: nil
    {:noreply, assign(socket, section: section || hd(visible_sections(socket)))}
  end

  @impl true
  def handle_event("section", %{"section" => section}, socket) when section in @sections do
    {:noreply, push_patch(socket, to: ~p"/app/settings?section=#{section}")}
  end

  def handle_event("validate-studio", %{"studio" => params}, socket) do
    changeset =
      socket.assigns.current_scope.studio
      |> Studio.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign(studio_form: to_form(changeset, as: :studio)) |> preview(params)}
  end

  def handle_event("save-studio", %{"studio" => params}, socket) do
    case Accounts.update_studio(socket.assigns.current_scope, params) do
      {:ok, studio} ->
        {:noreply,
         socket
         |> refresh_scope(studio)
         |> load()
         |> put_flash(:info, "Saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, studio_form: to_form(changeset, as: :studio))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Your role cannot change the studio's settings.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  def handle_event("validate-account", %{"user" => params}, socket) do
    changeset =
      socket.assigns.current_scope.user
      |> User.profile_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, account_form: to_form(changeset, as: :user))}
  end

  def handle_event("save-account", %{"user" => params}, socket) do
    case Accounts.update_profile(socket.assigns.current_scope.user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(current_scope: %{socket.assigns.current_scope | user: user})
         |> load()
         |> put_flash(:info, "Saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, account_form: to_form(changeset, as: :user))}
    end
  end

  def handle_event("change-password", %{"password" => params}, socket) do
    user = socket.assigns.current_scope.user

    cond do
      not User.valid_password?(user, params["current"] || "") ->
        {:noreply, put_flash(socket, :error, "That is not your current password.")}

      params["new"] != params["confirmation"] ->
        {:noreply, put_flash(socket, :error, "The two new passwords do not match.")}

      true ->
        case Accounts.update_password(user, %{
               "password" => params["new"],
               "password_confirmation" => params["confirmation"]
             }) do
          {:ok, _user} ->
            # Every other session is already gone — `update_password/2` deletes
            # the tokens — so this one has to go too, or the browser holds a
            # token the database no longer knows.
            {:noreply,
             socket
             |> put_flash(:info, "Password changed. Sign in again with the new one.")
             |> redirect(to: ~p"/sign-out")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, put_flash(socket, :error, first_error(changeset))}
        end
    end
  end

  def handle_event("change-plan", %{"plan" => key}, socket) do
    case Billing.change_plan(socket.assigns.current_scope, key) do
      {:ok, _subscription} ->
        {:noreply, socket |> load() |> put_flash(:info, "Plan changed.")}

      {:error, {:over_limit_for_plan, limit_key, used, allowed}} ->
        {:noreply, put_flash(socket, :error, downgrade_message(limit_key, used, allowed))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Your role cannot change the plan.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not change the plan: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel-plan", _params, socket) do
    case Billing.cancel(socket.assigns.current_scope) do
      {:ok, _subscription} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(:info, "Cancelled. You keep everything until the period ends.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not cancel: #{inspect(reason)}")}
    end
  end

  def handle_event("resume-plan", _params, socket) do
    case Billing.resume(socket.assigns.current_scope) do
      {:ok, _subscription} ->
        {:noreply, socket |> load() |> put_flash(:info, "Resumed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not resume: #{inspect(reason)}")}
    end
  end

  ## Data

  defp load(socket) do
    scope = socket.assigns.current_scope
    studio = scope.studio

    socket
    |> assign(studio: studio)
    |> assign(studio_form: to_form(Studio.changeset(studio, %{}), as: :studio))
    |> assign(account_form: to_form(User.profile_changeset(scope.user, %{}), as: :user))
    |> assign(time_zones: StudioOptions.time_zone_options(studio.time_zone))
    |> assign(format_sample: Formats.sample(studio))
    |> assign(usage: usage(scope))
    |> assign(subscription: Billing.get_subscription(scope))
    |> assign(plans: Billing.list_public_plans())
    |> assign_new(:section, fn -> hd(visible_sections(socket)) end)
  end

  # The sample line under the format fields has to follow what is in the boxes
  # right now, not what was last saved — that is the whole point of showing it.
  defp preview(socket, params) do
    studio = socket.assigns.studio

    sample =
      Formats.sample(%Studio{
        date_format: params["date_format"] || studio.date_format,
        time_format: params["time_format"] || studio.time_format,
        time_zone: params["time_zone"] || studio.time_zone
      })

    assign(socket, format_sample: sample)
  end

  defp refresh_scope(socket, studio) do
    scope = socket.assigns.current_scope

    assign(socket,
      current_scope: %{
        scope
        | studio: studio,
          currency: studio.base_currency,
          time_zone: studio.time_zone
      }
    )
  end

  defp usage(scope) do
    case Billing.usage(scope) do
      {:ok, usage} -> usage
      _ -> nil
    end
  end

  # Bytes are the right unit to enforce a cap in and the wrong one to read:
  # "allows 10737418240 storage bytes" is not a sentence anyone can act on.
  defp downgrade_message("storage_bytes", used, allowed),
    do:
      "That plan allows #{bytes(allowed)} of storage and you are using #{bytes(used)}. Delete or archive some galleries first."

  defp downgrade_message(key, used, allowed),
    do:
      "That plan allows #{allowed} #{String.downcase(humanise(key))} and you have #{used}. Reduce them first."

  defp first_error(%Ecto.Changeset{errors: [{field, {message, _}} | _]}),
    do: "#{field |> to_string() |> String.replace("_", " ") |> String.capitalize()} #{message}."

  defp first_error(_changeset), do: "That would not save."

  ## Sections

  @doc """
  The sections this scope may actually use.

  Filtered rather than shown-and-refused: a photographer offered a Billing tab
  that errors when they open it has been told something untrue about their own
  account.
  """
  def sections(%AperDesk.Scope{} = scope) do
    Enum.filter(@sections, fn
      section when section in ~w(studio formats) -> Authorization.can?(scope, :"studio.write")
      "plan" -> Authorization.can?(scope, :"billing.read")
      _account_or_roles -> true
    end)
  end

  defp visible_sections(socket), do: sections(socket.assigns.current_scope)

  ## Presentation

  def section_label("studio"), do: "Studio profile"
  def section_label("formats"), do: "Dates and money"
  def section_label("account"), do: "Your account"
  def section_label("roles"), do: "Roles and permissions"
  def section_label("plan"), do: "Plan and usage"

  defdelegate currency_options, to: StudioOptions
  defdelegate date_format_options, to: StudioOptions
  defdelegate time_format_options, to: StudioOptions
  defdelegate week_start_options, to: StudioOptions
  defdelegate sla_options, to: StudioOptions

  ## Roles

  def roles, do: Authorization.roles()

  def role_label(role), do: AperDeskWeb.TeamLive.role_label(to_string(role))

  @doc """
  The rows of the permission matrix.

  Grouped by the thing being acted on rather than listed as raw permission
  atoms, because "lead.write" is a fact about the code and "Create and edit
  leads" is the question a studio owner is actually asking.
  """
  def permission_rows do
    [
      {"See leads", :"lead.read"},
      {"Create and edit leads", :"lead.write"},
      {"See the calendar", :"job.read"},
      {"Book and change shoots", :"job.write"},
      {"Assign crew and hold dates", :"assignment.write"},
      {"Open client galleries", :"gallery.read"},
      {"Upload and deliver galleries", :"gallery.write"},
      {"Send quotes", :"quote.write"},
      {"See invoices and payments", :"invoice.read"},
      {"Raise invoices and take payment", :"payment.write"},
      {"Approve crew payouts", :"payout.write"},
      {"Manage the team", :"member.write"},
      {"Invite people", :"invitation.write"},
      {"Change automations", :"workflow.write"},
      {"See billing", :"billing.read"},
      {"Change the plan", :"billing.write"}
    ]
  end

  def holds?(role, permission), do: Authorization.holds?(role, permission)

  ## Plan

  def meter_label("storage_bytes"), do: "Storage"
  def meter_label("seats"), do: "Seats"
  def meter_label(key), do: humanise(key)

  def humanise(key), do: key |> to_string() |> String.replace("_", " ") |> String.capitalize()

  def meter_usage(%{key: "storage_bytes", used: used, limit: limit}),
    do: "#{bytes(used)} of #{bytes(limit)}"

  def meter_usage(%{used: used, limit: :unlimited}), do: "#{used} · no limit"
  def meter_usage(%{used: used, limit: limit}), do: "#{used} of #{limit}"

  def meter_fill(%{utilisation: value}) when is_float(value),
    do: "#{min(round(value * 100), 100)}%"

  def meter_fill(_meter), do: "0%"

  @doc "A meter's tone: nothing until it is nearly full, because a bar that is always red is ignored."
  def meter_tone(%{utilisation: value}) when is_float(value) and value >= 1.0, do: "bad"
  def meter_tone(%{utilisation: value}) when is_float(value) and value >= 0.85, do: "warn"
  def meter_tone(_meter), do: ""

  def bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{trim(bytes / 1_073_741_824)} GB"

  def bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{trim(bytes / 1_048_576)} MB"

  def bytes(bytes) when is_integer(bytes) and bytes >= 1024, do: "#{trim(bytes / 1024)} KB"
  def bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  def bytes(_bytes), do: "—"

  defp trim(value) do
    rounded = Float.round(value, 1)
    if rounded == Float.round(rounded), do: round(rounded), else: rounded
  end

  def plan_price(plan, "yearly"), do: money(plan.yearly_price_cents, plan.currency) <> " a year"
  def plan_price(plan, _monthly), do: money(plan.monthly_price_cents, plan.currency) <> " a month"

  def money(nil, _currency), do: "—"
  def money(cents, currency), do: cents |> Money.new(currency || "USD") |> Money.to_string()

  @doc "What the subscription is actually doing, said plainly."
  def subscription_line(_scope, nil), do: "No subscription"

  def subscription_line(scope, %{cancel_at_period_end: true} = subscription),
    do: "Cancelled — runs until #{Formats.date(scope, subscription.current_period_end)}"

  def subscription_line(scope, %{status: "trialing"} = subscription),
    do: "Trial — ends #{Formats.date(scope, subscription.trial_ends_at)}"

  def subscription_line(scope, %{current_period_end: %DateTime{} = ends} = subscription),
    do: "#{String.capitalize(subscription.status)} — renews #{Formats.date(scope, ends)}"

  def subscription_line(_scope, subscription), do: String.capitalize(subscription.status)
end
