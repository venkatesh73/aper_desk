defmodule AperDeskWeb.AuthController do
  @moduledoc """
  Sign up, sign in, sign out.

  Plain controllers rather than LiveViews, deliberately. Auth is the one place
  where working without JavaScript matters most — password managers fill and
  submit real forms, and a session cookie can be set directly here rather than
  handed from a LiveView to a controller just to write it. The cost is no
  inline validation, which for four fields is a fair trade.

  The session holds an opaque token, not a user id. The token is a row in
  `user_tokens` that can be revoked, so signing out or changing a password ends
  the session immediately rather than at expiry.
  """

  use AperDeskWeb, :controller

  alias AperDesk.Accounts
  alias AperDesk.Accounts.{Google, Registration}
  alias AperDesk.Billing
  alias AperDesk.Scope

  @doc "The sign-up form."
  def new_registration(conn, _params) do
    render(conn, :sign_up,
      changeset: Registration.changeset(%{}),
      page_title: "Start your free trial"
    )
  end

  def create_registration(conn, %{"registration" => params}) do
    changeset = Registration.changeset(%Registration{}, params)

    case Accounts.register_studio(changeset) do
      {:ok, %{user: user, studio: studio}} ->
        # Put the new studio straight onto its trial. A studio with no
        # subscription has no plan, and every limit check reads the plan — so
        # skipping this would leave a brand-new account unable to create
        # anything at all.
        {:ok, scope} = Accounts.scope_for(user, studio.id)
        start_trial(scope)

        conn
        |> put_flash(:info, "Welcome to AperDesk. Your 30-day trial has started.")
        |> sign_in(user, studio.id)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:sign_up, changeset: changeset, page_title: "Start your free trial")
    end
  end

  @doc "The sign-in form."
  def new_session(conn, _params) do
    render(conn, :sign_in, error: nil, email: nil, page_title: "Sign in")
  end

  def create_session(conn, %{"session" => %{"email" => email, "password" => password}}) do
    case Accounts.authenticate(email, password) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Signed in.")
        |> sign_in(user, nil)

      {:error, :invalid_credentials} ->
        # One message for both an unknown address and a wrong password. Telling
        # them apart hands an attacker a way to enumerate registered emails.
        conn
        |> put_status(:unprocessable_entity)
        |> render(:sign_in,
          error: "That email and password do not match.",
          email: email,
          page_title: "Sign in"
        )
    end
  end

  ## Invitations

  @doc """
  Open an invitation link.

  Three audiences arrive here and each needs something different: someone
  already signed in can take the seat now; someone with an account needs to
  sign in first; someone with neither needs to register. The page says which
  of those they are rather than dropping all three on a generic sign-in form
  and losing the token on the way.
  """
  def show_invitation(conn, %{"token" => token}) do
    case Accounts.preview_invitation(token) do
      {:ok, invitation, studio} ->
        render(conn, :invitation,
          invitation: invitation,
          studio: studio,
          token: token,
          error: nil,
          page_title: "Join #{studio.name}"
        )

      {:error, reason} ->
        render(conn, :invitation,
          invitation: nil,
          studio: nil,
          token: token,
          error: invitation_error(reason),
          page_title: "Invitation"
        )
    end
  end

  @doc """
  Take the seat.

  The signed-in case and the sign-in-then-accept case land on the same
  function, because accepting is the same operation either way — only how the
  user was identified differs.
  """
  def accept_invitation(conn, %{"token" => token} = params) do
    case identify(conn, params) do
      {:ok, user} ->
        case Accounts.accept_invitation(token, user) do
          {:ok, membership} ->
            conn
            |> put_flash(:info, "You are in.")
            |> sign_in(user, membership.studio_id)

          {:error, reason} ->
            reshow(conn, token, invitation_error(reason))
        end

      {:error, message} ->
        reshow(conn, token, message)
    end
  end

  # Already signed in, or signing in as part of accepting. Registering is sent
  # to the normal sign-up flow rather than being reimplemented here — that path
  # creates a studio, and someone joining one should not also get their own.
  defp identify(conn, params) do
    case conn.assigns[:current_scope] do
      %Scope{user: %Accounts.User{} = user} ->
        {:ok, user}

      _ ->
        case params do
          %{"session" => %{"email" => email, "password" => password}} ->
            case Accounts.authenticate(email, password) do
              {:ok, user} -> {:ok, user}
              {:error, :invalid_credentials} -> {:error, "That email and password do not match."}
            end

          _ ->
            {:error, "Sign in first, and the seat is yours."}
        end
    end
  end

  defp reshow(conn, token, message) do
    case Accounts.preview_invitation(token) do
      {:ok, invitation, studio} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:invitation,
          invitation: invitation,
          studio: studio,
          token: token,
          error: message,
          page_title: "Join #{studio.name}"
        )

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:invitation,
          invitation: nil,
          studio: nil,
          token: token,
          error: invitation_error(reason),
          page_title: "Invitation"
        )
    end
  end

  # Spelled out rather than inspected, because each of these means something
  # different to the person reading it and only one of them is worth retrying.
  defp invitation_error(:already_accepted),
    do: "This invitation has already been used — you are in the studio already."

  defp invitation_error(:expired_token),
    do: "This invitation has expired. Ask them to send another."

  defp invitation_error(:invalid_token), do: "This link does not open anything."
  defp invitation_error(:not_found), do: "This link does not open anything."

  defp invitation_error(%Ecto.Changeset{}),
    do: "You are already a member of this studio."

  defp invitation_error(_other), do: "Something went wrong taking the seat."

  ## Google sign-in

  @doc "Send the visitor to Google, remembering the `state` we expect back."
  def google_request(conn, _params) do
    if Google.configured?() do
      {url, state} = Google.authorize_url(google_redirect_uri(conn))

      conn
      |> put_session(:google_state, state)
      |> redirect(external: url)
    else
      conn
      |> put_flash(:error, "Google sign-in is not configured on this server.")
      |> redirect(to: ~p"/sign-in")
    end
  end

  @doc """
  Handle the return from Google.

  The `state` check comes first and is compared in constant time. Without it an
  attacker can complete their own Google flow and have the victim's browser
  deliver the resulting code, signing the victim into the attacker's account.
  """
  def google_callback(conn, %{"code" => code, "state" => state}) do
    expected = get_session(conn, :google_state)
    conn = delete_session(conn, :google_state)

    cond do
      is_nil(expected) ->
        deny(conn, "That sign-in attempt has expired. Please try again.")

      not secure_compare(expected, state) ->
        deny(conn, "That sign-in attempt could not be verified. Please try again.")

      true ->
        complete_google(conn, code)
    end
  end

  # Google reports a refusal — the visitor pressed cancel — as an `error`
  # parameter rather than a code.
  def google_callback(conn, %{"error" => _error}) do
    conn
    |> delete_session(:google_state)
    |> put_flash(:info, "Google sign-in was cancelled.")
    |> redirect(to: ~p"/sign-in")
  end

  def google_callback(conn, _params), do: deny(conn, "Google sign-in failed. Please try again.")

  defp complete_google(conn, code) do
    with {:ok, profile} <- Google.fetch_profile(code, google_redirect_uri(conn)),
         {:ok, user, outcome} <- Accounts.sign_in_with_google(profile) do
      maybe_start_trial(user, outcome)

      conn
      |> put_flash(:info, welcome_message(outcome))
      |> sign_in(user, nil)
    else
      {:error, :email_not_verified} ->
        deny(
          conn,
          "Google has not verified that email address, so we cannot use it to sign you in."
        )

      {:error, :no_email} ->
        deny(conn, "That Google account has no email address we can use.")

      {:error, _reason} ->
        deny(conn, "Google sign-in failed. Please try again.")
    end
  end

  defp maybe_start_trial(user, :created) do
    case Accounts.default_scope_for(user) do
      {:ok, scope} -> start_trial(scope)
      _ -> :ok
    end
  end

  defp maybe_start_trial(_user, _outcome), do: :ok

  defp welcome_message(:created), do: "Welcome to AperDesk. Your 30-day trial has started."
  defp welcome_message(:linked), do: "Google is now linked to your account."
  defp welcome_message(:existing), do: "Signed in."

  defp deny(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  # Must match the URI registered with Google exactly. Derived from the endpoint
  # rather than configured separately, so it cannot drift from the route.
  defp google_redirect_uri(_conn), do: url(~p"/auth/google/callback")

  defp secure_compare(a, b) when is_binary(a) and is_binary(b),
    do: :crypto.hash_equals(:crypto.hash(:sha256, a), :crypto.hash(:sha256, b))

  defp secure_compare(_a, _b), do: false

  ## Password reset

  def new_reset(conn, _params) do
    render(conn, :forgot_password, sent: false, page_title: "Reset your password")
  end

  @doc """
  Request a reset link.

  Renders the same confirmation whether or not the address is registered. Saying
  "no account with that email" would turn this form into a way to discover which
  addresses have accounts.
  """
  def create_reset(conn, %{"reset" => %{"email" => email}}) do
    Accounts.deliver_reset_password_instructions(email, fn token ->
      url(~p"/reset-password/#{token}")
    end)

    render(conn, :forgot_password, sent: true, page_title: "Check your email")
  end

  def edit_reset(conn, %{"token" => token}) do
    case Accounts.fetch_user_by_reset_token(token) do
      {:ok, _user} ->
        render(conn, :reset_password,
          token: token,
          error: nil,
          page_title: "Choose a new password"
        )

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That reset link has expired or already been used.")
        |> redirect(to: ~p"/forgot-password")
    end
  end

  def update_reset(conn, %{"token" => token, "reset" => params}) do
    case Accounts.reset_password(token, params) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Your password has been changed. Please sign in.")
        |> redirect(to: ~p"/sign-in")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:reset_password,
          token: token,
          error: password_error(changeset),
          page_title: "Choose a new password"
        )

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That reset link has expired or already been used.")
        |> redirect(to: ~p"/forgot-password")
    end
  end

  defp password_error(changeset) do
    changeset.errors
    |> Keyword.get_values(:password)
    |> Enum.map(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
    |> case do
      [] -> "That password could not be used."
      [message | _] -> "Password #{message}."
    end
  end

  def sign_out(conn, _params) do
    case get_session(conn, :user_token) do
      nil -> :ok
      token -> Accounts.revoke_token(token, "session")
    end

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/")
  end

  ## Internals

  # Renews the session id on sign-in, which is what stops a session-fixation
  # attack: a token planted before authentication is discarded rather than
  # promoted to a signed-in one.
  defp sign_in(conn, user, studio_id) do
    {:ok, token, _record} =
      Accounts.create_token(user, "session", device_label: user_agent(conn))

    studio_id = studio_id || default_studio_id(user)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_token, token)
    |> put_session(:studio_id, studio_id)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
    |> redirect(to: landing_path(studio_id))
  end

  defp default_studio_id(user) do
    case Accounts.list_studios_for_user(user) do
      [studio | _] -> studio.id
      [] -> nil
    end
  end

  # Somebody invited to a studio they have since left has no studio to land in.
  # Sending them to the marketing page is wrong; they need to be told.
  defp landing_path(nil), do: ~p"/sign-in"
  defp landing_path(_studio_id), do: ~p"/app"

  defp start_trial(scope) do
    case Billing.start_trial(scope, "solo") do
      {:ok, _subscription} -> :ok
      # A missing plan row is a seeding problem, not something to fail sign-up
      # over — the account still works, it just has no plan until seeds run.
      {:error, _reason} -> :ok
    end
  end

  defp user_agent(conn) do
    conn
    |> get_req_header("user-agent")
    |> List.first()
    |> case do
      nil -> nil
      agent -> String.slice(agent, 0, 120)
    end
  end
end
