defmodule AperDesk.Galleries.GalleryShare do
  @moduledoc """
  One named recipient's way in.

  Only the token hash is stored; the token itself is shown once, at creation.
  A leaked database backup therefore does not hand over working gallery links.
  Per-recipient rows exist because a wedding gallery goes to the couple, both
  sets of parents and the venue, and revoking the venue's link should not
  disturb anyone else's.
  """
  use AperDesk.Schema

  alias AperDesk.Galleries.Gallery

  @token_bytes 32

  schema "gallery_shares" do
    belongs_to :gallery, Gallery

    field :label, :string
    field :email, :string
    field :token_hash, :binary
    field :can_download, :boolean, default: true
    field :can_select, :boolean, default: true
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :view_count, :integer, default: 0

    # Returned to the caller on create, never persisted.
    field :token, :string, virtual: true, redact: true

    timestamps()
  end

  @doc """
  Build a share and mint its token. The plaintext token is available as
  `changeset.changes.token` for the one response that shows the link.
  """
  def changeset(share, attrs) do
    share
    |> cast(attrs, [:gallery_id, :label, :email, :can_download, :can_select, :expires_at])
    |> validate_required([:gallery_id, :label])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be a valid email address"
    )
    |> put_token()
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:gallery_id)
  end

  def revoke_changeset(share), do: change(share, revoked_at: DateTime.utc_now())

  @doc "Stamp a visit. Called on gallery load, so it must stay a single cheap update."
  def seen_changeset(share, at \\ DateTime.utc_now()),
    do: change(share, last_seen_at: at, view_count: (share.view_count || 0) + 1)

  @doc "Hash a token from a share link, for looking the share up."
  def hash_token(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "Whether this link still opens the gallery."
  def usable?(%__MODULE__{revoked_at: %DateTime{}}, _now), do: false
  def usable?(%__MODULE__{expires_at: nil}, _now), do: true

  def usable?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :gt

  defp put_token(changeset) do
    if changeset.data.token_hash do
      changeset
    else
      token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      changeset
      |> put_change(:token, token)
      |> put_change(:token_hash, hash_token(token))
    end
  end
end
