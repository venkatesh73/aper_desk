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
  @moduledoc "A sample image shown with a package."
  use AperDesk.Schema

  schema "package_media" do
    belongs_to :package, AperDesk.Catalog.Package
    field :storage_key, :string
    field :url, :string
    field :alt, :string
    field :position, :integer, default: 0
  end

  def changeset(media, attrs) do
    media
    |> cast(attrs, [:storage_key, :url, :alt, :position])
    |> validate_required([:storage_key])
  end
end
