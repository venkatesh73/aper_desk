defmodule AperDesk.Accounts.UserInvitation do
  @moduledoc """
  An offer of a seat in a studio.

  Invitations are addressed to an email rather than to a user, because the
  person being invited usually does not have an account yet — and if they do,
  accepting must attach to that existing identity rather than fork a second one.

  Like every other token in the system, only the hash is stored.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Membership, Studio, User}

  @rand_size 32
  @validity_seconds 60 * 60 * 24 * 14

  schema "user_invitations" do
    belongs_to :studio, Studio
    belongs_to :invited_by, User

    field :email, :string
    field :role, :string
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec

    field :token, :string, virtual: true, redact: true

    timestamps()
  end

  def validity_seconds, do: @validity_seconds

  @doc "Build an invitation, returning `{plaintext_token, changeset}`."
  def build(studio_id, attrs, invited_by_id \\ nil) do
    token = :crypto.strong_rand_bytes(@rand_size) |> Base.url_encode64(padding: false)

    changeset =
      %__MODULE__{}
      |> cast(attrs, [:email, :role])
      |> put_change(:studio_id, studio_id)
      |> put_change(:invited_by_id, invited_by_id)
      |> put_change(:token_hash, hash(token))
      |> put_change(
        :expires_at,
        DateTime.add(DateTime.utc_now(), @validity_seconds, :second)
      )
      |> validate_required([:email, :role])
      |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
      |> validate_format(:email, ~r/^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$/,
        message: "must be a valid email address"
      )
      |> validate_inclusion(:role, Membership.roles())
      |> unique_constraint(:token_hash)
      |> foreign_key_constraint(:studio_id)

    {token, changeset}
  end

  def accept_changeset(invitation, at \\ DateTime.utc_now()),
    do: change(invitation, accepted_at: at)

  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "Whether this invitation can still be accepted."
  def usable?(%__MODULE__{accepted_at: %DateTime{}}, _now), do: false

  def usable?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :gt
end
