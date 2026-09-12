defmodule AperDesk.Directory do
  @moduledoc """
  The public "find a photographer" side: listings, portfolios and reviews.

  A listing is published deliberately and separately from the studio's private
  record, so nothing a photographer writes in a client note can end up on a
  public page by accident.

  Reviews must reference a completed job, and `job_id` is uniquely indexed.
  That one constraint is the difference between a directory people trust and
  one they do not — a rating cannot exist without a booking behind it, and a
  job cannot be rated twice.
  """

  import Ecto.Query

  alias AperDesk.Authorization
  alias AperDesk.Directory.{Category, DirectoryListing, PortfolioItem, Review, StudioCategory}
  alias AperDesk.Repo
  alias AperDesk.Scheduling.Job
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias Ecto.Multi

  ## Listings

  def get_listing(%Scope{} = scope),
    do: Repo.get_by(DirectoryListing, studio_id: Scope.studio_id(scope))

  def upsert_listing(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"directory.write") do
      case get_listing(scope) do
        nil ->
          %DirectoryListing{}
          |> DirectoryListing.changeset(Scoped.put_studio(attrs, scope))
          |> Repo.insert()

        listing ->
          listing |> DirectoryListing.changeset(attrs) |> Repo.update()
      end
    end
  end

  def publish_listing(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"directory.write"),
         listing when not is_nil(listing) <- get_listing(scope) do
      listing |> DirectoryListing.publish_changeset() |> Repo.update()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Public search.

  Featured listings sort first, then rating, then review count — so a studio
  with one five-star review does not outrank one with fifty.
  """
  def search(opts \\ []) do
    DirectoryListing
    |> where([l], not is_nil(l.published_at))
    |> filter_listings(opts)
    |> order_by([l], desc: l.featured, desc: l.rating_avg, desc: l.rating_count)
    |> limit(^Keyword.get(opts, :limit, 25))
    |> preload(:studio)
    |> Repo.all()
  end

  @doc """
  One studio's public profile, by its slug.

  Published only. An unpublished listing reached by URL must be a 404 rather
  than a preview — a studio that pulled its listing has not agreed to be
  findable, and a page that answers 200 stays in the index.
  """
  def fetch_published(slug) when is_binary(slug) do
    query =
      from l in DirectoryListing,
        join: s in AperDesk.Accounts.Studio,
        on: s.id == l.studio_id,
        where: s.slug == ^slug and not is_nil(l.published_at),
        preload: [studio: s]

    case Repo.one(query) do
      nil -> {:error, :not_found}
      listing -> {:ok, listing}
    end
  end

  @doc """
  Every city with a published listing, and how many.

  This is what the directory's landing pages are built from, and what the
  sitemap enumerates: one page per city is the difference between ranking for
  "photographer" — which nobody wins — and ranking for "wedding photographer
  in Lisbon", which somebody searches for with intent to book.

  Cities with no listings are excluded, because a page promising
  photographers and showing none is worse for a searcher than no page.
  """
  def list_cities do
    Repo.all(
      from l in DirectoryListing,
        where: not is_nil(l.published_at) and not is_nil(l.city),
        group_by: [l.city, l.country_code],
        order_by: [desc: count(l.id), asc: l.city],
        select: %{city: l.city, country_code: l.country_code, count: count(l.id)}
    )
  end

  @doc "A URL-safe form of a city name, and the way back to matching listings."
  def city_slug(city) do
    city
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc """
  Find a city by its slug.

  Compared on the slug rather than the name so that "sao-paulo" reaches
  "São Paulo" — a URL cannot carry the accent, and a city page nobody can
  reach from a clean URL is a city page nobody links to.
  """
  def find_city(slug) do
    Enum.find(list_cities(), &(city_slug(&1.city) == slug))
  end

  @doc "Listings within `radius_km` of a point, nearest first."
  def search_near(latitude, longitude, radius_km, opts \\ []) do
    search(opts)
    |> Enum.map(&{&1, DirectoryListing.distance_km(&1, latitude, longitude)})
    |> Enum.filter(fn {_listing, distance} -> distance && distance <= radius_km end)
    |> Enum.sort_by(fn {_listing, distance} -> distance end)
    |> Enum.map(fn {listing, distance} -> %{listing: listing, distance_km: distance} end)
  end

  ## Categories

  def list_categories, do: Repo.all(from c in Category, order_by: c.position)

  def set_categories(%Scope{} = scope, category_ids) when is_list(category_ids) do
    with :ok <- Authorization.authorize(scope, :"directory.write") do
      studio_id = Scope.studio_id(scope)

      Repo.transaction(fn ->
        Repo.delete_all(from sc in StudioCategory, where: sc.studio_id == ^studio_id)

        Enum.map(category_ids, fn category_id ->
          Repo.insert!(
            StudioCategory.changeset(%StudioCategory{}, %{
              studio_id: studio_id,
              category_id: category_id
            })
          )
        end)
      end)
    end
  end

  ## Portfolio

  def list_portfolio(studio_id) do
    Repo.all(
      from p in PortfolioItem,
        where: p.studio_id == ^studio_id and p.published,
        order_by: [asc: p.position]
    )
  end

  def add_portfolio_item(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"directory.write") do
      %PortfolioItem{}
      |> PortfolioItem.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
    end
  end

  ## Reviews

  @doc """
  Invite a review for a completed job.

  Refuses unless the job is actually finished — asking for a rating before
  delivery is how directories end up full of ratings of nothing.
  """
  def request_review(%Scope{} = scope, job_id) do
    with {:ok, job} <- Scoped.fetch(Job, scope, job_id),
         :ok <- ensure_completed(job) do
      {:ok, job}
    end
  end

  @doc """
  Record a client's review and update the listing's denormalised rating in the
  same transaction, so the two can never disagree.
  """
  def create_review(%Scope{} = scope, attrs) do
    Multi.new()
    |> Multi.insert(:review, Review.changeset(%Review{}, Scoped.put_studio(attrs, scope)))
    |> Multi.run(:listing, fn repo, _ -> refresh_rating(repo, Scope.studio_id(scope)) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{review: review}} -> {:ok, review}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  def publish_review(%Scope{} = scope, review_id) do
    with :ok <- Authorization.authorize(scope, :"directory.write"),
         {:ok, review} <- Scoped.fetch(Review, scope, review_id) do
      Multi.new()
      |> Multi.update(:review, Review.publish_changeset(review))
      |> Multi.run(:listing, fn repo, _ -> refresh_rating(repo, Scope.studio_id(scope)) end)
      |> Repo.transaction()
      |> case do
        {:ok, %{review: review}} -> {:ok, review}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  def reply_to_review(%Scope{} = scope, review_id, reply) do
    with :ok <- Authorization.authorize(scope, :"directory.write"),
         {:ok, review} <- Scoped.fetch(Review, scope, review_id) do
      review |> Review.reply_changeset(reply) |> Repo.update()
    end
  end

  def list_reviews(studio_id) do
    Repo.all(
      from r in Review,
        where: r.studio_id == ^studio_id and not is_nil(r.published_at),
        order_by: [desc: r.published_at]
    )
  end

  ## Internals

  # Recomputed from the published reviews rather than incremented, so the
  # listing's rating is always re-derivable from the reviews behind it.
  defp refresh_rating(repo, studio_id) do
    reviews =
      repo.all(from r in Review, where: r.studio_id == ^studio_id and not is_nil(r.published_at))

    {average, count} = Review.aggregate(reviews)

    case repo.get_by(DirectoryListing, studio_id: studio_id) do
      nil -> {:ok, nil}
      listing -> repo.update(DirectoryListing.rating_changeset(listing, average, count))
    end
  end

  defp ensure_completed(%Job{status: status}) when status in ~w(shot delivered), do: :ok
  defp ensure_completed(%Job{status: status}), do: {:error, {:job_not_completed, status}}

  # A slug back to something a `lower(city)` comparison can match. Exact rather
  # than fuzzy: "porto" must not also match "Porto Alegre".
  defp slug_to_like(slug), do: slug |> String.replace("-", " ") |> String.downcase()

  defp filter_listings(query, opts) do
    Enum.reduce(opts, query, fn
      {:city, city}, q -> where(q, [l], ilike(l.city, ^city))
      {:city_slug, slug}, q -> where(q, [l], fragment("lower(?)", l.city) == ^slug_to_like(slug))
      {:country_code, code}, q -> where(q, [l], l.country_code == ^code)
      {:query, term}, q -> where(q, [l], ilike(l.headline, ^"%#{term}%"))
      {:max_price_cents, max}, q -> where(q, [l], l.from_price_cents <= ^max)
      _, q -> q
    end)
  end
end
