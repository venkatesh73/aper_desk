defmodule AperDesk.Accounts.Guardian do
  @moduledoc """
  JWT issuing and verification for the mobile client.

  Two token types, with deliberately different lifetimes:

    * `access` — 30 minutes, sent with every request. Short, because a stolen
      access token cannot be revoked without a database read on every call,
      which is exactly the cost JWTs exist to avoid. Short expiry is the
      mitigation.
    * `refresh` — 60 days, exchanged for a new access token. Backed by a row in
      `user_tokens`, so it *can* be revoked: signing out, or a password change,
      deletes the row and the refresh stops working immediately.

  That split is the whole design. Access tokens are fast and unrevocable but
  expire quickly; refresh tokens are revocable and checked against the database
  every time they are used.
  """

  use Guardian, otp_app: :aper_desk

  alias AperDesk.Accounts
  alias AperDesk.Accounts.User

  @access_ttl {30, :minutes}
  @refresh_ttl {60, :days}

  def subject_for_token(%User{id: id}, _claims), do: {:ok, to_string(id)}
  def subject_for_token(_resource, _claims), do: {:error, :invalid_resource}

  def resource_from_claims(%{"sub" => id}) do
    case Accounts.get_user(id) do
      nil -> {:error, :resource_not_found}
      user -> {:ok, user}
    end
  end

  def resource_from_claims(_claims), do: {:error, :invalid_claims}

  @doc """
  Issue an access/refresh pair for a signed-in user.

  The refresh token is also recorded in `user_tokens`, which is what makes
  revocation possible — see the module doc.
  """
  def sign_in(%User{} = user, opts \\ []) do
    studio_id = Keyword.get(opts, :studio_id)
    device = Keyword.get(opts, :device_label)

    claims = %{"typ" => "access"} |> maybe_put("std", studio_id)

    with {:ok, access, _} <-
           encode_and_sign(user, claims, token_type: "access", ttl: @access_ttl),
         {:ok, refresh, _} <-
           encode_and_sign(user, %{"typ" => "refresh"}, token_type: "refresh", ttl: @refresh_ttl),
         {:ok, _record} <-
           Accounts.store_token(user, "refresh", refresh, device_label: device) do
      {:ok, %{access_token: access, refresh_token: refresh, expires_in: 30 * 60}}
    end
  end

  @doc """
  Exchange a refresh token for a new access token.

  The database row is checked on every exchange, so a token revoked by a sign
  out or a password change stops working at once rather than at expiry.
  """
  def refresh_session(refresh_token) when is_binary(refresh_token) do
    with {:ok, claims} <- decode_and_verify(refresh_token, %{"typ" => "refresh"}),
         {:ok, user} <- resource_from_claims(claims),
         :ok <- ensure_refresh_live(user, refresh_token),
         {:ok, access, _} <-
           encode_and_sign(user, %{"typ" => "access"}, token_type: "access", ttl: @access_ttl) do
      {:ok, %{access_token: access, expires_in: 30 * 60}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Revoke one device's refresh token."
  def sign_out(%User{} = _user, refresh_token) when is_binary(refresh_token) do
    Accounts.revoke_token(refresh_token, "refresh")
    :ok
  end

  @doc "Revoke every refresh token for a user — the 'sign out everywhere' button."
  def sign_out_everywhere(%User{} = user), do: Accounts.revoke_all_tokens(user, "refresh")

  # The JWT is the credential; `user_tokens` holds only its hash. Looking it up
  # on every exchange is what turns an unrevocable JWT into a revocable session.
  defp ensure_refresh_live(user, refresh_token) do
    case Accounts.fetch_user_by_token(refresh_token, "refresh") do
      {:ok, %User{id: id}, _record} when id == user.id -> :ok
      {:ok, _other, _record} -> {:error, :token_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
