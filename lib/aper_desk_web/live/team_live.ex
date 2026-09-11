defmodule AperDeskWeb.TeamLive do
  @moduledoc """
  Who is in the studio, what they can see, and who has been asked to join.

  A member's card leads with their role because that is what the whole
  permission system turns on — `AperDesk.Authorization` answers "what can a
  finance user see?" from one table, and this screen is where that answer gets
  chosen. Changing it here changes what they can open on their next request.

  Removing someone marks the membership `left` rather than deleting it. Their
  name still has to render on the shoots they covered and the invoices they
  raised; a deleted row would turn all of that history into "Unknown".

  The last owner cannot be demoted or removed. `Accounts.update_member/3`
  enforces that, and the card hides the controls rather than offering an action
  that would be refused — a studio locked out of its own billing has no way
  back in from inside the product.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  alias AperDesk.Accounts
  alias AperDesk.Accounts.{Membership, UserInvitation}
  alias AperDesk.Formats
  alias AperDesk.Money

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Team")
     |> assign(editing: nil, invite_token: nil)
     |> assign(invite_form: blank_invite())
     |> load()}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.members, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      membership ->
        {:noreply,
         socket
         |> assign(editing: id)
         |> assign(member_form: to_form(Membership.changeset(membership, %{}), as: :membership))
         |> assign(
           day_rate_major:
             Money.to_major(membership.day_rate_cents, rate_currency(membership, socket))
         )}
    end
  end

  def handle_event("cancel-edit", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("validate-member", %{"membership" => params}, socket) do
    membership = Enum.find(socket.assigns.members, &(&1.id == socket.assigns.editing))

    changeset =
      membership
      |> Membership.changeset(with_rate(params, socket))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(member_form: to_form(changeset, as: :membership))
     |> assign(day_rate_major: params["day_rate_major"] || socket.assigns.day_rate_major)}
  end

  def handle_event("save-member", %{"membership" => params}, socket) do
    case Accounts.update_member(
           socket.assigns.current_scope,
           socket.assigns.editing,
           with_rate(params, socket)
         ) do
      {:ok, membership} ->
        {:noreply,
         socket
         |> assign(editing: nil)
         |> load()
         |> put_flash(:info, "#{name_of(membership, socket)} updated.")}

      {:error, :last_owner} ->
        {:noreply, put_flash(socket, :error, last_owner_message())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, member_form: to_form(changeset, as: :membership))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case Accounts.remove_member(socket.assigns.current_scope, id) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> assign(editing: nil)
         |> load()
         |> put_flash(:info, "Removed from the studio. Their past work keeps their name on it.")}

      {:error, :last_owner} ->
        {:noreply, put_flash(socket, :error, last_owner_message())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove them: #{inspect(reason)}")}
    end
  end

  def handle_event("invite", %{"invitation" => params}, socket) do
    case Accounts.invite_member(socket.assigns.current_scope, params) do
      {:ok, token, invitation} ->
        {:noreply,
         socket
         |> assign(invite_token: token, invited_email: invitation.email)
         |> assign(invite_form: blank_invite())
         |> load()
         |> put_flash(
           :info,
           "Invited #{invitation.email}. Copy the link now — it is not shown again."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, invite_form: to_form(changeset, as: :invitation))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not invite them: #{inspect(reason)}")}
    end
  end

  def handle_event("revoke-invite", %{"id" => id}, socket) do
    case Accounts.revoke_invitation(socket.assigns.current_scope, id) do
      {:ok, _invitation} ->
        {:noreply,
         socket |> assign(invite_token: nil) |> load() |> put_flash(:info, "Invitation revoked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not revoke it: #{inspect(reason)}")}
    end
  end

  # `UserInvitation` has no public changeset — `build/3` mints the token and
  # validates in one step — so the empty form is a plain map, and the errors
  # come back as the changeset `build/3` produced.
  defp blank_invite, do: to_form(%{"email" => "", "role" => "photographer"}, as: :invitation)

  ## Data

  defp load(socket) do
    scope = socket.assigns.current_scope

    members =
      case Accounts.list_members(scope) do
        {:ok, list} -> list
        _ -> []
      end

    invitations =
      case Accounts.list_invitations(scope) do
        {:ok, list} -> list
        _ -> []
      end

    socket
    |> assign(members: members)
    |> assign(invitations: invitations)
    |> assign(owners: Enum.count(members, &(&1.role == "owner" and &1.status == "active")))
  end

  # The day rate is typed in major units like every other price on the product.
  defp with_rate(params, socket) do
    currency = params["day_rate_currency"] || socket.assigns.current_scope.currency

    case params["day_rate_major"] do
      nil ->
        params

      "" ->
        params |> Map.put("day_rate_cents", nil) |> Map.put("day_rate_currency", nil)

      major ->
        params
        |> Map.put("day_rate_cents", Money.from_major(major, currency))
        |> Map.put("day_rate_currency", currency)
    end
  end

  defp rate_currency(%Membership{day_rate_currency: nil}, socket),
    do: socket.assigns.current_scope.currency

  defp rate_currency(%Membership{day_rate_currency: currency}, _socket), do: currency

  defp name_of(%Membership{id: id}, socket) do
    case Enum.find(socket.assigns.members, &(&1.id == id)) do
      %{user: %{name: name}} -> name
      _ -> "They"
    end
  end

  defp last_owner_message,
    do:
      "A studio has to keep at least one owner — nobody else can reach billing, and there is no way back in from inside the product."

  ## Presentation

  def roles, do: Membership.roles()

  def role_options,
    do: Enum.map(roles(), &{role_label(&1), &1})

  def role_label("owner"), do: "Owner"
  def role_label("photographer"), do: "Photographer"
  def role_label("finance"), do: "Finance"
  def role_label("hr"), do: "HR and people"
  def role_label("ops"), do: "Operations"
  def role_label(other), do: String.capitalize(other)

  @doc "What the role actually opens, said plainly. Mirrors `AperDesk.Authorization`."
  def role_detail("owner"), do: "Everything, including billing and closing the studio"
  def role_detail("photographer"), do: "Their own leads, shoots and galleries. No money."
  def role_detail("finance"), do: "Invoices, payments and payouts. No client galleries."
  def role_detail("hr"), do: "People, contracts and day rates. No client data."
  def role_detail("ops"), do: "Leads, scheduling, galleries and comms. No money."
  def role_detail(_other), do: ""

  def employment_options,
    do: [{"On staff", "staff"}, {"Freelance", "freelance"}]

  def status_tone("active"), do: "ok"
  def status_tone("invited"), do: "warn"
  def status_tone("suspended"), do: "bad"
  def status_tone(_other), do: ""

  def initials(%{user: %{name: name}}) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  def initials(_membership), do: "?"

  def member_name(%{user: %{name: name}}), do: name
  def member_name(_membership), do: "Unknown"

  def member_email(%{user: %{email: email}}), do: email
  def member_email(_membership), do: nil

  @doc """
  The line under the name: role, how they are engaged, and their rate.

  Assembled from what is actually set rather than padded with "—", so a card
  for a salaried owner does not carry an empty day-rate slot.
  """
  def member_line(%Membership{} = membership) do
    [
      role_label(membership.role),
      employment_word(membership.employment_type),
      day_rate(membership)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp employment_word("freelance"), do: "freelance"
  defp employment_word(_staff), do: "staff"

  def day_rate(%Membership{day_rate_cents: nil}), do: nil

  def day_rate(%Membership{day_rate_cents: cents, day_rate_currency: currency}),
    do: "#{Money.to_string(Money.new(cents, currency || "USD"))} a day"

  @doc "A contract running out is the one thing on this screen with a deadline."
  def contract_note(_scope, %Membership{contract_ends_on: nil}), do: nil

  def contract_note(scope, %Membership{contract_ends_on: date}) do
    case Date.diff(date, Formats.today_for(scope)) do
      days when days < 0 -> {"bad", "Contract ended #{Formats.date(scope, date)}"}
      days when days <= 30 -> {"warn", "Contract ends in #{days} days"}
      _ -> {"", "Contract to #{Formats.date(scope, date)}"}
    end
  end

  def last_seen(_scope, %Membership{last_active_at: nil}), do: "Never signed in"

  def last_seen(_scope, %Membership{last_active_at: at}) do
    case DateTime.diff(DateTime.utc_now(), at, :day) do
      0 -> "Here today"
      1 -> "Here yesterday"
      days when days < 30 -> "Last here #{days} days ago"
      _ -> "Not here in a month"
    end
  end

  @doc "Whether this member's role and seat can still be changed."
  def changeable?(%Membership{role: "owner"}, owners) when owners <= 1, do: false
  def changeable?(%Membership{}, _owners), do: true

  def invite_url(token), do: url(~p"/invitations/#{token}")

  def invitation_expiry(_scope, %UserInvitation{expires_at: nil}), do: "No expiry"

  def invitation_expiry(_scope, %UserInvitation{expires_at: at}) do
    case DateTime.diff(at, DateTime.utc_now(), :day) do
      days when days < 0 -> "Expired"
      0 -> "Expires today"
      1 -> "Expires tomorrow"
      days -> "Expires in #{days} days"
    end
  end

  def staff_count(members),
    do: Enum.count(members, &(&1.employment_type == "staff" and &1.status != "left"))

  def freelance_count(members),
    do: Enum.count(members, &(&1.employment_type == "freelance" and &1.status != "left"))
end
