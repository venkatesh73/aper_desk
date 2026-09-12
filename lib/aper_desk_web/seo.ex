defmodule AperDeskWeb.SEO do
  @moduledoc """
  What each page tells a search engine about itself.

  The product has two halves that want opposite things from a crawler. The
  marketing site and the photographer directory want to be found: they are how
  studios and couples arrive. Everything else — the signed-in app, and every
  page reached by a share token — must never be indexed, and that is a privacy
  requirement rather than an SEO preference. A `/g/<token>` link in a search
  result is a couple's wedding photographs handed to strangers, and tokens
  leak into the open the moment someone pastes one into a public forum.

  So the default here is `noindex`, and pages opt *in*. A new page added by
  somebody who never thinks about crawlers is private by accident rather than
  public by accident, and only one of those mistakes is recoverable.

  Each function returns only its own assigns, for the caller to `assign/2`.
  Merging into the caller's map would sweep up LiveView's reserved keys —
  `:flash` among them — and the failure reads as a framework complaint rather
  than as a mistake here.

  Nothing in this module talks to the database — a page that needs a description from a row builds it itself
  and passes it in, so the layout stays cheap on every render.
  """

  @site_name "AperDesk"
  @default_title "AperDesk · The studio system for photographers"
  @default_description "Capture leads, protect dates, deliver galleries and pay the crew. One place, five roles, no spreadsheet."

  @doc """
  Mark a page as indexable, with its canonical URL and social preview.

  `:title` and `:description` are what a search result shows, so they are the
  page's real promise rather than a keyword list. `:canonical` matters most on
  the directory, where the same studio is reachable through a city page, a
  category page and a search result — without it those are three pages
  competing with each other for one studio's ranking.
  """
  def index(opts) do
    %{
      seo_index: true,
      page_title: Keyword.get(opts, :title),
      seo_description: Keyword.get(opts, :description, @default_description),
      seo_canonical: Keyword.get(opts, :canonical),
      seo_image: Keyword.get(opts, :image),
      seo_type: Keyword.get(opts, :type, "website"),
      seo_schema: Keyword.get(opts, :schema)
    }
  end

  @doc "Keep a page out of the index. The default, and never wrong by accident."
  def noindex, do: %{seo_index: false}

  def site_name, do: @site_name
  def default_title, do: @default_title
  def default_description, do: @default_description

  @doc """
  The robots directive for a page.

  `noarchive` on top of `noindex` for token pages: a cached copy of a gallery
  is the same leak as an indexed one, a week later and harder to withdraw.
  """
  def robots(%{seo_index: true}), do: "index, follow, max-image-preview:large"
  def robots(_assigns), do: "noindex, nofollow, noarchive"

  @doc "JSON-LD for the product itself, for the marketing pages."
  def software_schema(url) do
    %{
      "@context" => "https://schema.org",
      "@type" => "SoftwareApplication",
      "name" => @site_name,
      "applicationCategory" => "BusinessApplication",
      "applicationSubCategory" => "Customer Relationship Management",
      "operatingSystem" => "Web",
      "url" => url,
      "description" => @default_description,
      "audience" => %{
        "@type" => "Audience",
        "audienceType" => "Professional photographers and photography studios"
      }
    }
  end

  @doc """
  JSON-LD for one studio's public profile.

  `LocalBusiness` rather than `Organization`, because a photographer is found
  by where they are — that is what puts a studio in a map pack for its own
  city. Aggregate rating is included only when there are real reviews behind
  it; inventing one is both a lie and, since 2023, a manual action.
  """
  def studio_schema(listing, studio, url, opts \\ []) do
    %{
      "@context" => "https://schema.org",
      "@type" => "ProfessionalService",
      "additionalType" => "https://schema.org/PhotographyBusiness",
      "name" => studio.name,
      "url" => url,
      "description" => listing.headline || listing.bio,
      "image" => listing.cover_url,
      "priceRange" => price_range(listing),
      "address" => address(listing),
      "geo" => geo(listing),
      "areaServed" => area_served(listing),
      "knowsLanguage" => listing.languages,
      "aggregateRating" => aggregate_rating(listing),
      "review" => Keyword.get(opts, :reviews, []) |> Enum.map(&review_schema/1)
    }
    |> prune()
  end

  @doc "JSON-LD for a search or city page: the list of studios on it."
  def listing_page_schema(listings, url, url_fun) do
    %{
      "@context" => "https://schema.org",
      "@type" => "ItemList",
      "url" => url,
      "numberOfItems" => length(listings),
      "itemListElement" =>
        listings
        |> Enum.with_index(1)
        |> Enum.map(fn {listing, position} ->
          %{
            "@type" => "ListItem",
            "position" => position,
            "url" => url_fun.(listing),
            "name" => listing.studio && listing.studio.name
          }
          |> prune()
        end)
    }
  end

  @doc """
  Breadcrumbs, which search results render as a path rather than a bare URL.

  Takes `{label, url}` pairs in order.
  """
  def breadcrumb_schema(crumbs) do
    %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" =>
        crumbs
        |> Enum.with_index(1)
        |> Enum.map(fn {{label, url}, position} ->
          %{"@type" => "ListItem", "position" => position, "name" => label, "item" => url}
        end)
    }
  end

  ## Internals

  defp price_range(%{from_price_cents: nil}), do: nil

  defp price_range(%{from_price_cents: cents, from_price_currency: currency}) do
    # A band rather than an exact figure: a profile says "from", and a search
    # result promising an exact price the studio never quoted is worse than
    # saying nothing.
    cents
    |> AperDesk.Money.new(currency || "USD")
    |> AperDesk.Money.to_string()
    |> Kernel.<>("+")
  end

  defp address(%{city: nil}), do: nil

  defp address(listing) do
    %{
      "@type" => "PostalAddress",
      "addressLocality" => listing.city,
      "addressCountry" => listing.country_code
    }
    |> prune()
  end

  defp geo(%{latitude: nil}), do: nil
  defp geo(%{longitude: nil}), do: nil

  defp geo(listing),
    do: %{
      "@type" => "GeoCoordinates",
      "latitude" => listing.latitude,
      "longitude" => listing.longitude
    }

  defp area_served(%{travels_worldwide: true}), do: "Worldwide"
  defp area_served(%{travel_radius_km: nil} = listing), do: listing.city

  defp area_served(listing),
    do: %{
      "@type" => "GeoCircle",
      "geoMidpoint" => geo(listing),
      "geoRadius" => to_string(listing.travel_radius_km * 1000)
    }

  # Only when the reviews are real. Google issues manual actions for invented
  # ratings, and a studio with no reviews reads more honestly with none shown.
  defp aggregate_rating(%{rating_count: count}) when count in [nil, 0], do: nil

  defp aggregate_rating(listing) do
    %{
      "@type" => "AggregateRating",
      "ratingValue" => Decimal.to_string(listing.rating_avg),
      "reviewCount" => listing.rating_count,
      "bestRating" => "5",
      "worstRating" => "1"
    }
  end

  defp review_schema(review) do
    %{
      "@type" => "Review",
      "reviewRating" => %{
        "@type" => "Rating",
        "ratingValue" => to_string(review.rating),
        "bestRating" => "5"
      },
      "author" => %{"@type" => "Person", "name" => review.author_name},
      "reviewBody" => review.body,
      "datePublished" => review.published_at && DateTime.to_date(review.published_at)
    }
    |> prune()
  end

  # Schema.org readers treat an empty value as a claim about nothing, and
  # Google's validator warns on it. Dropping the key says less, accurately.
  defp prune(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end
end
