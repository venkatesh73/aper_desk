defmodule AperDesk.Repo.Migrations.CreateUserIdentities do
  use Ecto.Migration

  @moduledoc """
  Federated sign-in identities, one row per (provider, account).

  A separate table rather than a `google_id` column on `users`, because the
  moment a second provider is added a column-per-provider becomes a table of
  mostly-null columns with no constraint holding it together.

  Storing the provider's stable subject id matters: matching on email alone
  breaks the moment someone changes the address on their Google account, and
  silently creates a second account for them.
  """

  def change do
    create table(:user_identities, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

      add :provider, :string, null: false
      # The provider's own immutable id for the account — Google's `sub`.
      add :provider_uid, :string, null: false
      add :email, :citext
      add :name, :string
      add :avatar_url, :string
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # One account per provider identity. Without this, two concurrent first
    # sign-ins from the same Google account would create two users.
    create unique_index(:user_identities, [:provider, :provider_uid])

    # A user connects a given provider at most once.
    create unique_index(:user_identities, [:user_id, :provider])

    create constraint(:user_identities, :user_identities_provider_is_known,
             check: "provider IN ('google')"
           )
  end
end
