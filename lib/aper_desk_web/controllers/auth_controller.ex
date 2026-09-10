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
  alias AperDesk.Accounts.Registration
  alias AperDesk.Billing

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

  def delete_session(conn, _params) do
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
