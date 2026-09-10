defmodule AperDeskWeb.PasswordResetTest do
  @moduledoc """
  Password reset, including the two properties that matter most: the form
  cannot be used to discover which addresses have accounts, and a completed
  reset ends every existing session.
  """

  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Swoosh.TestAssertions

  alias AperDesk.Accounts

  @password "a sufficiently long passphrase"
  @new_password "an entirely different passphrase"

  setup do
    %{user: user} = studio_fixture()
    %{user: user}
  end

  describe "GET /forgot-password" do
    test "renders the form", %{conn: conn} do
      html = conn |> get(~p"/forgot-password") |> html_response(200)
      assert html =~ "Reset your password"
    end

    test "is linked from the sign-in page", %{conn: conn} do
      html = conn |> get(~p"/sign-in") |> html_response(200)
      assert html =~ ~s(href="/forgot-password")
    end
  end

  describe "POST /forgot-password" do
    test "emails a link to a registered address", %{conn: conn, user: user} do
      conn = post(conn, ~p"/forgot-password", reset: %{"email" => user.email})

      assert html_response(conn, 200) =~ "Check your email"

      assert_email_sent(fn email ->
        assert email.subject =~ "Reset your AperDesk password"
        assert {_name, address} = List.first(email.to)
        assert address == user.email
      end)
    end

    test "says exactly the same thing for an unknown address", %{conn: conn, user: user} do
      known = post(conn, ~p"/forgot-password", reset: %{"email" => user.email})
      unknown = post(build_conn(), ~p"/forgot-password", reset: %{"email" => "ghost@example.com"})

      # Any difference here turns the reset form into a way to discover which
      # addresses have accounts. The CSRF token differs per response by design,
      # so it is normalised out before comparing.
      assert strip_csrf(html_response(known, 200)) == strip_csrf(html_response(unknown, 200))
    end

    test "does not send anything to an unknown address", %{conn: conn} do
      post(conn, ~p"/forgot-password", reset: %{"email" => "ghost@example.com"})
      refute_email_sent()
    end

    test "requesting a second link invalidates the first", %{conn: conn, user: user} do
      post(conn, ~p"/forgot-password", reset: %{"email" => user.email})
      first = extract_token()

      post(build_conn(), ~p"/forgot-password", reset: %{"email" => user.email})
      second = extract_token()

      refute first == second
      assert {:error, :invalid_token} = Accounts.fetch_user_by_reset_token(first)
      assert {:ok, _user} = Accounts.fetch_user_by_reset_token(second)
    end
  end

  describe "resetting" do
    setup %{conn: conn, user: user} do
      post(conn, ~p"/forgot-password", reset: %{"email" => user.email})
      %{token: extract_token()}
    end

    test "renders the form for a valid token", %{conn: conn, token: token} do
      html = conn |> get(~p"/reset-password/#{token}") |> html_response(200)
      assert html =~ "Choose a new password"
    end

    test "redirects an expired or unknown token away", %{conn: conn} do
      conn = get(conn, ~p"/reset-password/not-a-real-token")
      assert redirected_to(conn) == ~p"/forgot-password"
    end

    test "changes the password and consumes the token", %{conn: conn, token: token, user: user} do
      conn =
        put(conn, ~p"/reset-password/#{token}", reset: %{"password" => @new_password})

      assert redirected_to(conn) == ~p"/sign-in"
      assert {:ok, _user} = Accounts.authenticate(user.email, @new_password)
      assert {:error, :invalid_credentials} = Accounts.authenticate(user.email, @password)
      assert {:error, :invalid_token} = Accounts.fetch_user_by_reset_token(token)
    end

    test "ends every existing session", %{conn: conn, token: token, user: user} do
      {:ok, session_token, _} = Accounts.create_token(user, "session")
      assert {:ok, _user, _} = Accounts.fetch_user_by_token(session_token, "session")

      put(conn, ~p"/reset-password/#{token}", reset: %{"password" => @new_password})

      # If the reset happened because someone else had the old password, leaving
      # their session alive defeats the point of resetting it.
      assert {:error, :invalid_token} = Accounts.fetch_user_by_token(session_token, "session")
    end

    test "rejects a password that is too short", %{conn: conn, token: token} do
      conn = put(conn, ~p"/reset-password/#{token}", reset: %{"password" => "short"})
      assert html_response(conn, 422) =~ "at least 12 character"
    end

    test "tells the user their password changed", %{conn: conn, token: token} do
      put(conn, ~p"/reset-password/#{token}", reset: %{"password" => @new_password})

      # The reset email from setup is still in the mailbox, so this looks for a
      # matching message rather than asserting on whichever arrived first.
      assert Enum.any?(sent_emails(), &(&1.subject =~ "password was changed"))
    end
  end

  defp sent_emails do
    {:messages, messages} = Process.info(self(), :messages)
    for {:email, %Swoosh.Email{} = email} <- messages, do: email
  end

  # The link is only ever in the email, which is the point — so the test reads
  # it from there rather than reaching into the tokens table.
  defp extract_token do
    body =
      sent_emails()
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Swoosh.Email{subject: "Reset your AperDesk password", text_body: body} -> body
        _ -> nil
      end)

    [_, token] = Regex.run(~r{/reset-password/([^\s]+)}, body)
    token
  end

  defp strip_csrf(html),
    do: Regex.replace(~r{content="[^"]+"}, html, ~s(content="CSRF"))
end
