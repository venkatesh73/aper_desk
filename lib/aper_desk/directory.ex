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
    opts
    |> base_query()
    |> sort_listings(Keyword.get(opts, :sort))
    |> limit(^Keyword.get(opts, :limit, 24))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> preload(:studio)
    |> Repo.all()
  end

  @doc "How many published listings match, ignoring paging."
  def count_matching(opts \\ []) do
    opts |> base_query() |> exclude(:order_by) |> Repo.aggregate(:count, :id)
  end

  @doc """
  The counts beside each filter.

  Each facet is counted with every filter applied *except its own*, which is
  what makes the numbers useful: showing "Fine art (0)" while fine art is the
  active filter tells a searcher nothing, whereas showing what they would get
  by switching to it tells them whether it is worth the click.
  """
  def facets(opts \\ []) do
    %{
      total: count_matching(opts),
      categories: category_facets(opts),
      languages: language_facets(opts),
      ratings: rating_facets(opts)
    }
  end

  defp category_facets(opts) do
    without = Keyword.delete(opts, :categories)

    counts =
      without
      |> base_query()
      |> exclude(:order_by)
      |> join(:inner, [l], sc in StudioCategory, on: sc.studio_id == l.studio_id)
      |> join(:inner, [l, sc], c in Category, on: c.id == sc.category_id)
      |> group_by([l, sc, c], [c.key, c.name, c.position])
      |> order_by([l, sc, c], asc: c.position)
      |> select([l, sc, c], %{key: c.key, name: c.name, count: count(l.id)})
      |> Repo.all()

    counts
  end

  defp language_facets(opts) do
    without = Keyword.delete(opts, :languages)

    without
    |> base_query()
    |> exclude(:order_by)
    |> select([l], l.languages)
    |> Repo.all()
    |> List.flatten()
    |> Enum.frequencies()
    |> Enum.sort_by(fn {language, count} -> {-count, language} end)
    |> Enum.map(fn {language, count} -> %{language: language, count: count} end)
  end

  defp rating_facets(opts) do
    without = Keyword.delete(opts, :min_rating)

    Map.new([{"4.5", Decimal.new("4.5")}, {"4.0", Decimal.new("4.0")}], fn {label, min} ->
      {label, without |> Keyword.put(:min_rating, min) |> count_matching()}
    end)
    |> Map.put("any", count_matching(without))
  end

  defp base_query(opts) do
    DirectoryListing
    |> where([l], not is_nil(l.published_at))
    |> filter_listings(opts)
  end

  # Nulls last everywhere it matters. A studio that has not published a price
  # is not the cheapest one, and sorting it to the top of "price, low to high"
  # would reward leaving the field blank.
  defp sort_listings(query, "price"),
    do: order_by(query, [l], asc_nulls_last: l.from_price_cents, desc: l.rating_avg)

  defp sort_listings(query, "rating"),
    do: order_by(query, [l], desc_nulls_last: l.rating_avg, desc: l.rating_count)

  defp sort_listings(query, "response"),
    do: order_by(query, [l], asc_nulls_last: l.response_time_minutes, desc: l.rating_avg)

  defp sort_listings(query, _recommended),
    do:
      order_by(query, [l], desc: l.featured, desc_nulls_last: l.rating_avg, desc: l.rating_count)

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

  ## What a profile page shows

  @doc """
  A studio's public packages, cheapest first, with what each includes.

  `public` is the studio's own switch — a package built for one corporate
  client at a negotiated rate is not a price the world should read as this
  studio's rate. Archived packages are excluded for the same reason.
  """
  def list_public_packages(studio_id) do
    Repo.all(
      from p in AperDesk.Catalog.Package,
        where: p.studio_id == ^studio_id and p.public and is_nil(p.archived_at),
        order_by: [asc: p.price_cents, asc: p.position],
        preload: [items: ^from(i in AperDesk.Catalog.PackageItem, order_by: i.position)]
    )
  end

  @doc """
  Categories for many studios at once, as `%{studio_id => [name]}`.

  One query for a page of results rather than one per card. The cards need
  this to say what a studio shoots, and a directory that issues twenty-five
  extra queries to draw one grid will not stay fast for long.
  """
  def categories_for(studio_ids) when is_list(studio_ids) do
    Repo.all(
      from sc in StudioCategory,
        join: c in Category,
        on: c.id == sc.category_id,
        where: sc.studio_id in ^studio_ids,
        order_by: [desc: sc.primary_category, asc: c.position],
        select: {sc.studio_id, c.name}
    )
    |> Enum.group_by(fn {studio_id, _name} -> studio_id end, fn {_id, name} -> name end)
  end

  @doc "The categories one studio is listed under, primary first."
  def studio_categories(studio_id) do
    Repo.all(
      from sc in StudioCategory,
        join: c in Category,
        on: c.id == sc.category_id,
        where: sc.studio_id == ^studio_id,
        order_by: [desc: sc.primary_category, asc: c.position],
        select: %{key: c.key, name: c.name, primary: sc.primary_category}
    )
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
      {:city, city}, q ->
        where(q, [l], ilike(l.city, ^city))

      {:city_slug, slug}, q ->
        where(q, [l], fragment("lower(?)", l.city) == ^slug_to_like(slug))

      {:country_code, code}, q ->
        where(q, [l], l.country_code == ^code)

      # Headline and bio both, because a searcher typing "elopement" is
      # describing the work, and the work is described in the bio at least as
      # often as in the one-line headline.
      {:query, term}, q when is_binary(term) and term != "" ->
        pattern = "%#{term}%"
        where(q, [l], ilike(l.headline, ^pattern) or ilike(l.bio, ^pattern))

      {:max_price_cents, max}, q ->
        where(q, [l], l.from_price_cents <= ^max)

      {:min_price_cents, min}, q ->
        where(q, [l], l.from_price_cents >= ^min)

      {:min_rating, min}, q ->
        where(q, [l], l.rating_avg >= ^min)

      # Any of the chosen languages, not all of them. A couple who speak
      # English and German want whoever can talk to them, not the rarer
      # photographer who happens to speak both.
      {:languages, [_ | _] = languages}, q ->
        where(q, [l], fragment("? && ?", l.languages, ^languages))

      {:categories, [_ | _] = keys}, q ->
        where(
          q,
          [l],
          l.studio_id in subquery(
            from sc in StudioCategory,
              join: c in Category,
              on: c.id == sc.category_id,
              where: c.key in ^keys,
              select: sc.studio_id
          )
        )

      {:available_on, %Date{} = date}, q ->
        # Asked of Scheduling rather than joined here, so the directory learns
        # only which studios are busy and nothing about what they are busy with.
        where(q, [l], l.studio_id not in ^AperDesk.Scheduling.studios_busy_on(date))

      _, q ->
        q
    end)
  end
end
