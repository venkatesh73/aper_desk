defmodule AperDesk.Galleries.Gallery do
  @moduledoc """
  A set of finished frames handed to a client.

  `media_count` and `bytes_total` are maintained by a database trigger, never by
  application code — see the galleries migration. They are read on every upload
  to enforce the plan's storage cap, and a counter that drifts would either
  block a paying studio or silently let storage run away, so the write lives
  next to the data it counts.

  The delivery window is stored as an absolute `expires_at` rather than derived
  from the plan, so buying a 30-day extension for one gallery is a single field
  update instead of a special case threaded through plan logic.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}
  alias AperDesk.Crm.Contact
  alias AperDesk.Galleries.{GalleryMedia, GalleryShare}
  alias AperDesk.Scheduling.Job

  @statuses ~w(draft ready delivered archived purged)
  # The statuses that consume plan storage. Kept in sync with the
  # `studio_usage_gallery_rollup` trigger in the billing migration.
  @live_statuses ~w(ready delivered)

  schema "galleries" do
    belongs_to :studio, Studio
    belongs_to :job, Job
    belongs_to :contact, Contact
    belongs_to :owner, User

    field :title, :string
    field :slug, :string
    field :description, :string
    field :cover_media_id, :binary_id

    field :status, :string, default: "draft"

    field :delivered_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    field :purge_after, :utc_datetime_usec

    field :download_enabled, :boolean, default: true
    field :download_limit, :integer
    field :download_count, :integer, default: 0
    field :selection_limit, :integer
    field :watermark_enabled, :boolean, default: false
    field :show_studio_badge, :boolean, default: true

    field :password_hash, :string
    field :requires_otp, :boolean, default: false

    # Trigger-maintained. Never cast.
    field :media_count, :integer, default: 0
    field :bytes_total, :integer, default: 0

    # Virtual: set when creating a gallery, hashed into `password_hash`.
    field :password, :string, virtual: true, redact: true

    has_many :media, GalleryMedia, foreign_key: :gallery_id
    has_many :shares, GalleryShare, foreign_key: :gallery_id

    timestamps()
  end

  def statuses, do: @statuses
  def live_statuses, do: @live_statuses

  def changeset(gallery, attrs) do
    gallery
    |> cast(attrs, [
      :studio_id,
      :job_id,
      :contact_id,
      :owner_id,
      :title,
      :slug,
      :description,
      :cover_media_id,
      :download_enabled,
      :download_limit,
      :selection_limit,
      :watermark_enabled,
      :show_studio_badge,
      :requires_otp,
      :password
    ])
    |> validate_required([:studio_id, :title])
    |> put_slug()
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "may only contain lowercase letters, numbers and hyphens"
    )
    |> validate_number(:download_limit, greater_than: 0)
    |> validate_number(:selection_limit, greater_than: 0)
    |> put_password_hash()
    |> unique_constraint([:studio_id, :slug])
    |> foreign_key_constraint(:studio_id)
  end

  @doc """
  Publish the gallery to the client, opening a delivery window of `window_days`.

  Separate from `changeset/2` because delivering is the moment storage starts
  counting against the plan and the expiry clock starts; both must happen
  together or neither.
  """
  def deliver_changeset(gallery, window_days, at \\ DateTime.utc_now())
      when is_integer(window_days) and window_days > 0 do
    gallery
    |> change(
      status: "delivered",
      delivered_at: gallery.delivered_at || at,
      expires_at: DateTime.add(at, window_days * 24 * 60 * 60, :second),
      archived_at: nil
    )
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Push an already-delivered gallery's expiry out by `days` (the extension add-on)."
  def extend_changeset(%__MODULE__{expires_at: nil}, _days),
    do: raise(ArgumentError, "cannot extend a gallery that has not been delivered")

  def extend_changeset(%__MODULE__{} = gallery, days) when is_integer(days) and days > 0 do
    # Extend from whichever is later: an expiry already passed should not push
    # the new window into the past.
    base = latest(gallery.expires_at, DateTime.utc_now())

    change(gallery,
      expires_at: DateTime.add(base, days * 24 * 60 * 60, :second),
      status: "delivered",
      archived_at: nil,
      purge_after: nil
    )
  end

  @doc """
  Archive an expired gallery. Files stay recoverable for `recovery_days` before
  the purge worker deletes them, which is the promise made on the pricing page.
  """
  def archive_changeset(gallery, recovery_days \\ 30, at \\ DateTime.utc_now()) do
    change(gallery,
      status: "archived",
      archived_at: at,
      purge_after: DateTime.add(at, recovery_days * 24 * 60 * 60, :second)
    )
  end

  @doc "Whether this gallery's bytes count against the plan's storage cap."
  def live?(%__MODULE__{status: status}), do: status in @live_statuses

  @doc "Whether the delivery window has closed."
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) == :gt

  @doc """
  Whether a client may still download. A nil `download_limit` means unlimited —
  distinct from a limit of zero, which means downloads are off.
  """
  def downloadable?(%__MODULE__{download_enabled: false}), do: false
  def downloadable?(%__MODULE__{download_limit: nil}), do: true

  def downloadable?(%__MODULE__{download_limit: limit, download_count: count}),
    do: count < limit

  @doc "Days left in the delivery window, or nil if undelivered."
  def days_remaining(%__MODULE__{expires_at: nil}, _now), do: nil

  def days_remaining(%__MODULE__{expires_at: expires_at}, now),
    do: max(DateTime.diff(expires_at, now, :second), 0) |> div(86_400)

  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        case get_field(changeset, :title) do
          nil -> changeset
          title -> put_change(changeset, :slug, slugify(title))
        end

      slug ->
        put_change(changeset, :slug, slugify(slug))
    end
  end

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
  end

  defp put_password_hash(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      "" ->
        changeset |> put_change(:password_hash, nil) |> delete_change(:password)

      password ->
        changeset
        |> put_change(:password_hash, Argon2.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end

  defp latest(%DateTime{} = a, %DateTime{} = b),
    do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
end
