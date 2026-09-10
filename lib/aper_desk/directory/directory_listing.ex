defmodule AperDesk.Directory.DirectoryListing do
  @moduledoc """
  A studio's public face in the "find a photographer" directory.

  A listing is a separately published record rather than a view derived from
  the studio's private data. That is the whole point: a studio controls exactly
  what the world sees, and nothing a photographer writes in a private note can
  leak into a public page by accident. It also means an unpublished listing can
  be drafted and previewed without any of it being visible.

  `rating_avg` and `rating_count` are denormalised because directory search
  sorts on them, and sorting on an aggregate over `reviews` would make the main
  public query the slowest one in the app.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio

  schema "directory_listings" do
    belongs_to :studio, Studio

    field :headline, :string
    field :bio, :string
    field :city, :string
    field :country_code, :string
    field :latitude, :float
    field :longitude, :float
    field :travels_worldwide, :boolean, default: false
    field :travel_radius_km, :integer

    field :from_price_cents, :integer
    field :from_price_currency, :string
    field :languages, {:array, :string}, default: []
    field :response_time_minutes, :integer

    field :cover_url, :string
    field :published_at, :utc_datetime_usec
    field :featured, :boolean, default: false

    # Maintained by the reviews context when a review is published.
    field :rating_avg, :decimal
    field :rating_count, :integer, default: 0

    timestamps()
  end

  def changeset(listing, attrs) do
    listing
    |> cast(attrs, [
      :studio_id,
      :headline,
      :bio,
      :city,
      :country_code,
      :latitude,
      :longitude,
      :travels_worldwide,
      :travel_radius_km,
      :from_price_cents,
      :from_price_currency,
      :languages,
      :response_time_minutes,
      :cover_url
    ])
    |> validate_required([:studio_id, :headline, :city, :country_code])
    |> validate_length(:headline, min: 10, max: 120)
    |> validate_format(:country_code, ~r/^[A-Z]{2}$/,
      message: "must be a two-letter ISO country code"
    )
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> validate_number(:travel_radius_km, greater_than: 0)
    |> validate_number(:from_price_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:studio_id)
    |> foreign_key_constraint(:studio_id)
  end

  @doc """
  Publish the listing.

  Requires the fields a searcher needs to make a decision — a listing that
  appears in results with no bio and no cover wastes the searcher's click and
  reflects badly on the directory, so publishing is gated rather than trusted.
  """
  def publish_changeset(listing, at \\ DateTime.utc_now()) do
    listing
    |> change(published_at: listing.published_at || at)
    |> validate_required([:headline, :bio, :city, :country_code, :cover_url])
  end

  def unpublish_changeset(listing), do: change(listing, published_at: nil)

  @doc "Apply a recomputed rating after a review is published or withdrawn."
  def rating_changeset(listing, average, count),
    do: change(listing, rating_avg: average, rating_count: count)

  def published?(%__MODULE__{published_at: %DateTime{}}), do: true
  def published?(%__MODULE__{}), do: false

  def from_price(%__MODULE__{from_price_cents: nil}), do: nil

  def from_price(%__MODULE__{} = listing),
    do: AperDesk.Money.new(listing.from_price_cents, listing.from_price_currency || "USD")

  @doc "Whether the studio would travel `km` for a shoot."
  def covers_distance?(%__MODULE__{travels_worldwide: true}, _km), do: true
  def covers_distance?(%__MODULE__{travel_radius_km: nil}, _km), do: false
  def covers_distance?(%__MODULE__{travel_radius_km: radius}, km), do: km <= radius

  @doc """
  Great-circle distance in km between a listing and a point.

  Haversine, done here rather than in Postgres, so the directory does not need
  PostGIS for what is a sort key over a few hundred candidate rows.
  """
  def distance_km(%__MODULE__{latitude: nil}, _lat, _lon), do: nil
  def distance_km(%__MODULE__{longitude: nil}, _lat, _lon), do: nil

  def distance_km(%__MODULE__{latitude: lat1, longitude: lon1}, lat2, lon2) do
    earth_radius_km = 6371.0
    dlat = deg_to_rad(lat2 - lat1)
    dlon = deg_to_rad(lon2 - lon1)

    a =
      :math.pow(:math.sin(dlat / 2), 2) +
        :math.cos(deg_to_rad(lat1)) * :math.cos(deg_to_rad(lat2)) *
          :math.pow(:math.sin(dlon / 2), 2)

    earth_radius_km * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end

  defp deg_to_rad(degrees), do: degrees * :math.pi() / 180
end
