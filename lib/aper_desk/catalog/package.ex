defmodule AperDesk.Catalog.Package do
  @moduledoc "What the studio sells: price, inclusions and sample work."
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Catalog.{PackageItem, PackageMedia}

  schema "packages" do
    belongs_to :studio, Studio

    field :name, :string
    field :slug, :string
    field :summary, :string
    field :description, :string
    field :shoot_type, :string, default: "other"

    field :price_cents, :integer, default: 0
    field :price_currency, :string, default: "USD"
    field :deposit_percent, :integer, default: 25

    field :duration_minutes, :integer
    field :crew_size, :integer, default: 1
    field :delivery_days, :integer, default: 30
    field :edited_image_count, :integer

    field :public, :boolean, default: true
    field :position, :integer, default: 0
    field :archived_at, :utc_datetime_usec

    has_many :items, PackageItem, on_replace: :delete
    has_many :media, PackageMedia, on_replace: :delete

    timestamps()
  end

  def changeset(package, attrs) do
    package
    |> cast(attrs, [
      :studio_id,
      :name,
      :slug,
      :summary,
      :description,
      :shoot_type,
      :price_cents,
      :price_currency,
      :deposit_percent,
      :duration_minutes,
      :crew_size,
      :delivery_days,
      :edited_image_count,
      :public,
      :position
    ])
    |> validate_required([:studio_id, :name, :price_cents, :price_currency])
    |> maybe_slug()
    |> validate_number(:price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:crew_size, greater_than: 0)
    |> validate_inclusion(:price_currency, AperDesk.Money.supported_currencies())
    |> validate_inclusion(:shoot_type, AperDesk.Crm.Lead.shoot_types())
    |> cast_assoc(:items)
    |> unique_constraint([:studio_id, :slug])
  end

  @doc "The deposit due at signature, derived rather than stored so it cannot drift."
  def deposit(%__MODULE__{} = package) do
    package.price_cents
    |> AperDesk.Money.new(package.price_currency)
    |> AperDesk.Money.percent_bps(package.deposit_percent * 100)
  end

  def price(%__MODULE__{} = package),
    do: AperDesk.Money.new(package.price_cents, package.price_currency)

  defp maybe_slug(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :name)} do
      {nil, name} when is_binary(name) ->
        put_change(
          changeset,
          :slug,
          name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
        )

      _ ->
        changeset
    end
  end
end

defmodule AperDesk.Catalog.PackageItem do
  @moduledoc "One line of what a package includes (or explicitly does not)."
  use AperDesk.Schema

  schema "package_items" do
    belongs_to :package, AperDesk.Catalog.Package
    field :label, :string
    field :detail, :string
    field :included, :boolean, default: true
    field :position, :integer, default: 0
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:label, :detail, :included, :position])
    |> validate_required([:label])
  end
end

defmodule AperDesk.Catalog.PackageMedia do
  @moduledoc """
  A piece of sample work shown with a package.

  Stills and video are held to different size limits — 5 MB and 10 MB — because
  they are different things: a photograph over 5 MB is an unprocessed export
  nobody wants to download on a phone, while ten seconds of usable video cannot
  fit in that at all.

  The limits are checked here as well as in the browser and in the upload
  socket. The browser's check is a convenience the client controls, and
  LiveView's is per upload rather than per file kind — this is the one that
  runs against the bytes actually on disk, so it is the one that decides.
  """
  use AperDesk.Schema

  @kinds ~w(image video)

  @max_bytes %{"image" => 5 * 1_048_576, "video" => 10 * 1_048_576}

  schema "package_media" do
    belongs_to :package, AperDesk.Catalog.Package
    belongs_to :studio, AperDesk.Accounts.Studio

    field :kind, :string, default: "image"
    field :storage_key, :string
    field :url, :string
    field :alt, :string
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer, default: 0
    field :position, :integer, default: 0
  end

  def kinds, do: @kinds

  @doc "The cap for one file of this kind, in bytes."
  def max_bytes(kind), do: Map.get(@max_bytes, kind, @max_bytes["image"])

  @doc "The cap as a person would say it: `5 MB`."
  def max_label(kind), do: "#{div(max_bytes(kind), 1_048_576)} MB"

  def changeset(media, attrs) do
    media
    |> cast(attrs, [
      :package_id,
      :studio_id,
      :kind,
      :storage_key,
      :url,
      :alt,
      :filename,
      :content_type,
      :byte_size,
      :position
    ])
    |> validate_required([:studio_id, :storage_key, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_size()
    |> foreign_key_constraint(:package_id)
  end

  defp validate_size(changeset) do
    kind = get_field(changeset, :kind)
    size = get_field(changeset, :byte_size)

    if is_integer(size) and kind in @kinds and size > max_bytes(kind) do
      add_error(
        changeset,
        :byte_size,
        "is larger than #{max_label(kind)} — the limit for #{plural(kind)}"
      )
    else
      changeset
    end
  end

  defp plural("video"), do: "video"
  defp plural(_image), do: "images"
end
