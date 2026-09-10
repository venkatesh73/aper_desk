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
    |> Repo.all()
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

  defp filter_listings(query, opts) do
    Enum.reduce(opts, query, fn
      {:city, city}, q -> where(q, [l], ilike(l.city, ^city))
      {:country_code, code}, q -> where(q, [l], l.country_code == ^code)
      {:query, term}, q -> where(q, [l], ilike(l.headline, ^"%#{term}%"))
      {:max_price_cents, max}, q -> where(q, [l], l.from_price_cents <= ^max)
      _, q -> q
    end)
  end
end
