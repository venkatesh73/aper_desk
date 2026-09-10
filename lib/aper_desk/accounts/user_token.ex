defmodule AperDesk.Accounts.UserToken do
  @moduledoc """
  Session, password-reset, confirmation and mobile-refresh tokens, in one table.

  Only the SHA-256 hash is stored. The plaintext is returned once, at creation,
  and never again — so a database leak yields no usable sessions and no
  password-reset links. That is the single most valuable property of this table
  and the reason it does not simply store the token.

  Contexts carry their own validity windows because the risk differs: a reset
  link that lives as long as a session is a standing account takeover.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.User

  @rand_size 32

  # Validity per context, in seconds.
  @validity %{
    "session" => 60 * 60 * 24 * 60,
    "refresh" => 60 * 60 * 24 * 30,
    "reset_password" => 60 * 60,
    "confirm" => 60 * 60 * 24 * 7,
    "change_email" => 60 * 60 * 24
  }

  @contexts Map.keys(@validity)

  schema "user_tokens" do
    belongs_to :user, User

    field :token_hash, :binary
    field :context, :string
    field :sent_to, :string
    field :device_label, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    field :token, :string, virtual: true, redact: true

    timestamps(updated_at: false)
  end

  def contexts, do: @contexts
  def validity_seconds(context), do: Map.fetch!(@validity, context)

  @doc """
  Mint a token for `user` in `context`.

  Returns `{plaintext_token, changeset}`. The plaintext is handed back
  separately rather than left on the struct so it is obvious at the call site
  that this is the only moment it exists.
  """
  def build(%User{} = user, context, opts \\ []) when context in @contexts do
    token = :crypto.strong_rand_bytes(@rand_size) |> Base.url_encode64(padding: false)

    changeset =
      %__MODULE__{}
      |> change(
        user_id: user.id,
        token_hash: hash(token),
        context: context,
        sent_to: Keyword.get(opts, :sent_to, user.email),
        device_label: Keyword.get(opts, :device_label),
        expires_at: DateTime.add(DateTime.utc_now(), validity_seconds(context), :second)
      )
      |> unique_constraint([:context, :token_hash])

    {token, changeset}
  end

  @doc """
  Record a token that was minted elsewhere — a Guardian JWT, say.

  Stores only the hash, exactly as `build/3` does. This exists so a JWT can be
  made revocable: the JWT itself is the credential, and this row is the record
  that says it is still valid.
  """
  def build_from(%User{} = user, context, token, opts \\ [])
      when context in @contexts and is_binary(token) do
    %__MODULE__{}
    |> change(
      user_id: user.id,
      token_hash: hash(token),
      context: context,
      sent_to: Keyword.get(opts, :sent_to, user.email),
      device_label: Keyword.get(opts, :device_label),
      expires_at: DateTime.add(DateTime.utc_now(), validity_seconds(context), :second)
    )
    |> unique_constraint([:context, :token_hash])
  end

  def revoke_changeset(token), do: change(token, revoked_at: DateTime.utc_now())

  @doc "Hash a plaintext token for lookup. The only way a token is ever matched."
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "Whether the token is still live."
  def usable?(%__MODULE__{revoked_at: %DateTime{}}, _now), do: false
  def usable?(%__MODULE__{expires_at: nil}, _now), do: true

  def usable?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :gt
end
