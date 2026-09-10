defmodule AperDesk.GuardianTest do
  @moduledoc """
  The access/refresh split is the security design, so these tests assert the
  properties that make it work: token types are not interchangeable, and a
  refresh token is genuinely revocable even though the JWT itself stays
  cryptographically valid.
  """

  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.Accounts
  alias AperDesk.Accounts.{Guardian, User}

  setup do
    %{user: user, studio: studio} = studio_fixture()
    %{user: user, studio: studio}
  end

  test "sign_in issues both tokens", %{user: user, studio: studio} do
    assert {:ok, tokens} = Guardian.sign_in(user, studio_id: studio.id, device_label: "iPhone")
    assert is_binary(tokens.access_token)
    assert is_binary(tokens.refresh_token)
    assert tokens.expires_in == 1800
  end

  test "an access token cannot be used as a refresh token, or vice versa", %{user: user} do
    {:ok, tokens} = Guardian.sign_in(user)

    assert {:ok, _} = Guardian.decode_and_verify(tokens.access_token, %{"typ" => "access"})
    assert {:error, _} = Guardian.decode_and_verify(tokens.access_token, %{"typ" => "refresh"})
    assert {:error, _} = Guardian.decode_and_verify(tokens.refresh_token, %{"typ" => "access"})
  end

  test "a refresh token exchanges for a new access token", %{user: user} do
    {:ok, tokens} = Guardian.sign_in(user)
    assert {:ok, refreshed} = Guardian.refresh_session(tokens.refresh_token)
    assert is_binary(refreshed.access_token)
  end

  test "signing out revokes the refresh token, though the JWT still verifies", %{user: user} do
    {:ok, tokens} = Guardian.sign_in(user)

    assert :ok = Guardian.sign_out(user, tokens.refresh_token)
    assert {:error, _} = Guardian.refresh_session(tokens.refresh_token)

    # Revocation lives in the database row, not the signature — which is the
    # whole reason refresh tokens are backed by a row at all.
    assert {:ok, _} = Guardian.decode_and_verify(tokens.refresh_token, %{"typ" => "refresh"})
  end

  test "changing a password revokes every device", %{user: user} do
    {:ok, phone} = Guardian.sign_in(user, device_label: "iPhone")
    {:ok, tablet} = Guardian.sign_in(user, device_label: "iPad")

    user = Repo.get!(User, user.id)
    {:ok, _} = Accounts.update_password(user, %{password: "an entirely new passphrase"})

    assert {:error, _} = Guardian.refresh_session(phone.refresh_token)
    assert {:error, _} = Guardian.refresh_session(tablet.refresh_token)
  end

  test "sign out everywhere revokes all devices", %{user: user} do
    {:ok, tokens} = Guardian.sign_in(user)
    assert :ok = Guardian.sign_out_everywhere(user)
    assert {:error, _} = Guardian.refresh_session(tokens.refresh_token)
  end
end
