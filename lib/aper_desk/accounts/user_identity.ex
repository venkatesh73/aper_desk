defmodule AperDesk.Accounts.UserIdentity do
  @moduledoc """
  A federated sign-in linked to a user.

  `provider_uid` is the provider's own immutable id — Google's `sub` claim, not
  the email address. Emails change; the subject does not. Matching on email
  alone would silently create a second account for anyone who changed the
  address on their Google profile.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.User

  @providers ~w(google)

  schema "user_identities" do
    belongs_to :user, User

    field :provider, :string
    field :provider_uid, :string
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :last_used_at, :utc_datetime_usec

    timestamps()
  end

  def providers, do: @providers

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:user_id, :provider, :provider_uid, :email, :name, :avatar_url, :last_used_at])
    |> validate_required([:user_id, :provider, :provider_uid])
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint([:provider, :provider_uid],
      message: "is already linked to another account"
    )
    |> unique_constraint([:user_id, :provider])
    |> foreign_key_constraint(:user_id)
  end

  def used_changeset(identity), do: change(identity, last_used_at: DateTime.utc_now())
end
