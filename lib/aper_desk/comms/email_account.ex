defmodule AperDesk.Comms.EmailAccount do
  @moduledoc """
  A mailbox the studio has connected, by IMAP or OAuth.

  Every credential column goes through `AperDesk.Encrypted.Binary`, so what
  lands in a backup is ciphertext. This is the one place in the app where a
  leak would hand an attacker a working mailbox rather than merely data about
  one, which is why the encryption is at the column and not left to the disk.

  `last_uid` is the IMAP resume point. Storing it means a sync that dies
  halfway resumes where it stopped instead of re-reading the whole mailbox and
  re-capturing leads that were already captured.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}
  alias AperDesk.Encrypted

  @providers ~w(imap gmail outlook smtp)
  @sync_states ~w(idle syncing error disconnected)

  schema "email_accounts" do
    belongs_to :studio, Studio
    belongs_to :user, User

    field :address, :string
    field :provider, :string, default: "imap"
    field :display_name, :string

    field :imap_host, :string
    field :imap_port, :integer
    field :imap_username, :string
    field :imap_password_encrypted, Encrypted.Binary, redact: true
    field :smtp_host, :string
    field :smtp_port, :integer
    field :smtp_username, :string
    field :smtp_password_encrypted, Encrypted.Binary, redact: true
    field :oauth_refresh_token_encrypted, Encrypted.Binary, redact: true
    field :oauth_expires_at, :utc_datetime_usec

    field :sync_state, :string, default: "idle"
    field :last_synced_at, :utc_datetime_usec
    field :last_uid, :integer
    field :last_error, :string
    field :capture_enabled, :boolean, default: true

    timestamps()
  end

  def providers, do: @providers
  def sync_states, do: @sync_states

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :studio_id,
      :user_id,
      :address,
      :provider,
      :display_name,
      :imap_host,
      :imap_port,
      :imap_username,
      :imap_password_encrypted,
      :smtp_host,
      :smtp_port,
      :smtp_username,
      :smtp_password_encrypted,
      :oauth_refresh_token_encrypted,
      :oauth_expires_at,
      :capture_enabled
    ])
    |> validate_required([:studio_id, :address, :provider])
    |> validate_inclusion(:provider, @providers)
    |> validate_format(:address, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be a valid email address"
    )
    |> validate_number(:imap_port, greater_than: 0, less_than: 65_536)
    |> validate_number(:smtp_port, greater_than: 0, less_than: 65_536)
    |> validate_credentials()
    |> unique_constraint([:studio_id, :address],
      message: "this mailbox is already connected"
    )
  end

  @doc "Record the outcome of a sync run."
  def sync_changeset(account, attrs) do
    account
    |> cast(attrs, [:sync_state, :last_synced_at, :last_uid, :last_error])
    |> validate_inclusion(:sync_state, @sync_states)
  end

  @doc "Whether an OAuth access token needs refreshing before the next call."
  def token_expired?(%__MODULE__{oauth_expires_at: nil}, _now), do: false

  def token_expired?(%__MODULE__{oauth_expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :lt

  # An IMAP account without a host cannot sync, and would sit in the UI looking
  # connected while silently capturing nothing. Fail at the boundary instead.
  defp validate_credentials(changeset) do
    case get_field(changeset, :provider) do
      "imap" -> validate_required(changeset, [:imap_host, :imap_username])
      "smtp" -> validate_required(changeset, [:smtp_host, :smtp_username])
      _ -> changeset
    end
  end
end
