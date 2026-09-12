defmodule AperDeskWeb.DirectoryLive do
  @moduledoc """
  The half of the product a couple arrives at, not a studio.

  Three shapes, because they answer three different searches:

    * `/photographers` — the hub. Ranks for nothing much on its own; its job
      is to link to the city pages so a crawler can find them.
    * `/photographers/:city` — where the traffic is. "Wedding photographer in
      Lisbon" is a search somebody makes intending to book; "photographer" is
      not a search anybody wins.
    * `/photographers/:city/:slug` — one studio, which is the page that
      converts and the one the studio will link to from their own site.

  Every one of them sets its own canonical, because the same studio is
  reachable from a search, a city page and a category — and without a
  canonical those are three pages competing for one studio's ranking.

  Filters live in the query string rather than in socket state. A couple who
  find three photographers they like want to send that page to each other, and
  a filter set that exists only inside a socket cannot be sent to anyone. It
  also means the back button works.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents, only: [empty: 1]

  alias AperDesk.Directory
  alias AperDesk.Money
  alias AperDeskWeb.SEO

  @page_size 12
  @filter_keys ~w(q where style lang rating budget what date only_available price_min price_max sort)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_layout: false, categories: Directory.list_categories())}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, load(socket, socket.assigns.live_action, params)}

  ## Filtering

  # One handler for the whole form. The sidebar, the search bar and the sort
  # all end up in the same place: a patch to a URL that describes the search.
  # Replaces rather than merges. The form carries the whole search on every
  # change, so what it sends *is* the new state — and an unchecked box sends
  # nothing at all, which a merge would read as "leave that filter on".
  # Paging resets with it, because a narrowed search starts at the first page.
  @impl true
  def handle_event("filter", params, socket),
    do: {:noreply, patch(socket, Map.drop(params, ["_target"]), replace: true)}

  def handle_event("clear-filters", _params, socket),
    do: {:noreply, patch(socket, %{}, replace: true)}

  def handle_event("more", _params, socket) do
    {:noreply, patch(socket, %{"per" => to_string(socket.assigns.per + @page_size)})}
  end

  def handle_event("shoot-type", %{"type" => type}, socket),
    do: {:noreply, assign(socket, shoot_type: if(type == "", do: nil, else: type))}

  @impl true
  def handle_info({:combobox, "sort", value}, socket),
    do: {:noreply, patch(socket, %{"sort" => value})}

  def handle_info({:combobox, "budget", value}, socket),
    do: {:noreply, patch(socket, %{"budget" => value})}

  def handle_info({:combobox, "what", value}, socket),
    do: {:noreply, patch(socket, %{"what" => value})}

  defp patch(socket, changes, opts \\ []) do
    params =
      if opts[:replace],
        do: prune_params(changes),
        else: socket.assigns.params |> Map.merge(changes) |> prune_params()

    push_patch(socket, to: path_for(socket.assigns, params))
  end

  # Empty strings and unchecked boxes are absent, not present-and-blank. A URL
  # carrying `?q=&city=&sort=` is a worse thing to share than one carrying the
  # two filters somebody actually chose — and LiveView's own `_unused_*`
  # markers for untouched fields have no business in it at all.
  defp prune_params(params) do
    params
    |> Enum.reject(fn {key, value} ->
      String.starts_with?(key, "_unused_") or value in [nil, "", [], "false"] or
        default_sort?(key, value)
    end)
    |> Map.new()
  end

  # `?sort=recommended` is the default, so carrying it makes a second URL for
  # a page that is already reachable without it.
  defp default_sort?("sort", "recommended"), do: true
  defp default_sort?(_key, _value), do: false

  defp path_for(%{live_action: :city, city: city}, params),
    do: ~p"/photographers/#{Directory.city_slug(city.city)}?#{params}"

  defp path_for(_assigns, params), do: ~p"/photographers?#{params}"

  ## The hub and the city pages — the same search, differently framed

  defp load(socket, :index, params), do: results(socket, nil, params)

  defp load(socket, :city, %{"city" => slug} = params) do
    case Directory.find_city(slug) do
      nil ->
        socket
        |> put_flash(:error, "No photographers listed there yet.")
        |> push_navigate(to: ~p"/photographers")

      city ->
        results(socket, city, params)
    end
  end

  ## One studio

  defp load(socket, :show, %{"city" => city_slug, "slug" => slug} = params) do
    case Directory.fetch_published(slug) do
      {:error, :not_found} ->
        # A 404 rather than a redirect. An unpublished or missing studio that
        # answers 200 anywhere stays in the index pointing at nothing.
        raise AperDeskWeb.NotFoundError, "no published listing for #{slug}"

      {:ok, listing} ->
        reviews = Directory.list_reviews(listing.studio_id)
        portfolio = Directory.list_portfolio(listing.studio_id)
        canonical = profile_url(listing)

        socket
        |> assign(listing: listing, reviews: reviews, portfolio: portfolio)
        |> assign(packages: Directory.list_public_packages(listing.studio_id))
        |> assign(studio_categories: Directory.studio_categories(listing.studio_id))
        |> assign(shoot_type: nil, city_slug: city_slug)
        |> assign(enquiry_path: enquiry_path(listing.studio))
        |> assign(availability: availability_line(listing, params))
        |> assign(
          SEO.index(
            title: "#{listing.studio.name} · #{listing.city}",
            description: profile_description(listing),
            canonical: canonical,
            image: listing.cover_url,
            type: "profile",
            schema:
              SEO.studio_schema(listing, listing.studio, canonical,
                reviews: Enum.take(reviews, 5)
              )
          )
        )
    end
  end

  # Links at the studio's own enquiry form when they have opened one. A CTA
  # that goes nowhere is worse than one that is absent.
  defp enquiry_path(studio) do
    case AperDesk.Comms.default_public_form(studio.id) do
      nil -> nil
      form -> ~p"/f/#{studio.slug}/#{form.slug}"
    end
  end

  # Only answered when the searcher carried a date in from the results page.
  # Volunteering "free on every date we know of" would be telling a stranger
  # the studio's diary is empty.
  defp availability_line(listing, params) do
    with date when not is_nil(date) <- date_param(params["date"]),
         busy <- AperDesk.Scheduling.studios_busy_on(date) do
      if listing.studio_id in busy,
        do: "Already booked on #{Calendar.strftime(date, "%-d %b %Y")}",
        else: "Free on #{Calendar.strftime(date, "%-d %b %Y")}"
    else
      _no_date -> nil
    end
  end

  defp results(socket, city, params) do
    filters = filters_from(params, city)
    per = per_page(params)

    listings = Directory.search(Keyword.merge(filters, limit: per))
    total = Directory.count_matching(filters)
    facets = Directory.facets(filters)

    socket
    |> assign(params: Map.drop(params, ["city"]), city: city, per: per)
    |> assign(listings: listings, total: total, facets: facets)
    |> assign(tags: Directory.categories_for(Enum.map(listings, & &1.studio_id)))
    |> assign(cities: Directory.list_cities())
    |> assign(chosen: chosen_from(params))
    |> assign(seo_for(city, listings, total, params))
  end

  defp seo_for(nil, listings, total, _params) do
    SEO.index(
      title: "Find a photographer",
      description:
        "Compare #{count_line(total)} by their work, what they charge and how fast they reply. One enquiry reaches them directly.",
      canonical: url(~p"/photographers"),
      schema: SEO.listing_page_schema(listings, url(~p"/photographers"), &profile_url/1)
    )
  end

  defp seo_for(city, _listings, total, params) do
    slug = Directory.city_slug(city.city)
    where = [city.city, city.country_code] |> Enum.reject(&is_nil/1) |> Enum.join(", ")

    base =
      SEO.index(
        title: "Photographers in #{city.city}",
        description:
          "#{count_line(total)} in #{where}. See their work, what they charge, and how quickly they reply — then enquire with one message.",
        canonical: url(~p"/photographers/#{slug}"),
        schema:
          SEO.breadcrumb_schema([
            {"Photographers", url(~p"/photographers")},
            {city.city, url(~p"/photographers/#{slug}")}
          ])
      )

    # A filtered view is the same set of studios in a different order. Left
    # indexable it becomes hundreds of near-duplicate pages competing with the
    # city page they were cut from, so the canonical stays on the city page and
    # only the unfiltered view is offered to a crawler.
    if filtered?(params), do: Map.put(base, :seo_index, false), else: base
  end

  defp filtered?(params),
    do: Enum.any?(@filter_keys, &(params[&1] not in [nil, "", []]))

  ## Internals

  defp filters_from(params, city) do
    []
    |> maybe_put(:query, params["q"])
    |> maybe_put(:city_slug, city && Directory.city_slug(city.city))
    |> maybe_put(:city, is_nil(city) && params["where"])
    |> maybe_put(:categories, list_param(params, "style") ++ list_param(params, "what"))
    |> maybe_put(:languages, list_param(params, "lang"))
    |> maybe_put(:min_rating, decimal_param(params["rating"]))
    |> maybe_put(
      :min_price_cents,
      money_param(params["price_min"]) || budget_floor(params["budget"])
    )
    |> maybe_put(
      :max_price_cents,
      money_param(params["price_max"]) || budget_ceiling(params["budget"])
    )
    |> maybe_put(:available_on, available_on(params))
    |> maybe_put(:sort, params["sort"])
  end

  # The date only narrows anything when the searcher asks it to. Somebody
  # typing a date to carry into an enquiry has not thereby said they want
  # every studio with a booking that day hidden.
  defp available_on(%{"only_available" => "true"} = params), do: date_param(params["date"])
  defp available_on(_params), do: nil

  defp list_param(params, key) do
    case params[key] do
      nil -> []
      "" -> []
      value when is_binary(value) -> [value]
      values when is_list(values) -> Enum.reject(values, &(&1 in [nil, "", "false"]))
      _other -> []
    end
  end

  defp decimal_param(nil), do: nil
  defp decimal_param(""), do: nil

  defp decimal_param(value) do
    case Decimal.parse(value) do
      {decimal, _rest} -> decimal
      :error -> nil
    end
  end

  defp date_param(nil), do: nil
  defp date_param(""), do: nil

  defp date_param(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  # Budgets are read in the listing's own currency by the query, which is a
  # simplification worth naming: a studio pricing in INR is compared against a
  # bracket a searcher chose in whatever they were shown.
  defp budget_floor("3000-6000"), do: 300_000
  defp budget_floor("6000-10000"), do: 600_000
  defp budget_floor("10000+"), do: 1_000_000
  defp budget_floor(_other), do: nil

  defp budget_ceiling("under-3000"), do: 300_000
  defp budget_ceiling("3000-6000"), do: 600_000
  defp budget_ceiling("6000-10000"), do: 1_000_000
  defp budget_ceiling(_other), do: nil

  # Typed in whole currency units, stored in minor ones.
  defp money_param(nil), do: nil
  defp money_param(""), do: nil

  defp money_param(value) do
    case Integer.parse(value) do
      {major, _rest} when major >= 0 -> major * 100
      _other -> nil
    end
  end

  defp per_page(params) do
    case Integer.parse(params["per"] || "") do
      {n, _rest} when n > 0 and n <= 240 -> n
      _other -> @page_size
    end
  end

  defp chosen_from(params) do
    %{
      styles: list_param(params, "style"),
      languages: list_param(params, "lang"),
      rating: params["rating"],
      budget: params["budget"],
      price_min: params["price_min"],
      price_max: params["price_max"],
      what: params["what"],
      sort: params["sort"] || "recommended",
      date: params["date"],
      only_available: params["only_available"] == "true",
      q: params["q"],
      where: params["where"]
    }
  end

  defp maybe_put(opts, _key, value) when value in [nil, "", [], false], do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp count_line(0), do: "no photographers yet"
  defp count_line(1), do: "1 photographer"
  defp count_line(n), do: "#{n} photographers"

  defp profile_description(listing) do
    [
      listing.headline,
      listing.city && "Based in #{listing.city}",
      from_price(listing),
      rating_line(listing)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(". ")
    |> String.slice(0, 300)
  end

  defp rating_line(%{rating_count: count}) when count in [nil, 0], do: nil

  defp rating_line(listing),
    do: "Rated #{Decimal.to_string(listing.rating_avg)} from #{listing.rating_count} reviews"

  ## Presentation

  def profile_url(listing) do
    url(
      ~p"/photographers/#{Directory.city_slug(listing.city || "elsewhere")}/#{listing.studio.slug}"
    )
  end

  def city_path(city), do: ~p"/photographers/#{Directory.city_slug(city.city)}"

  def from_price(%{from_price_cents: nil}), do: nil

  def from_price(listing),
    do:
      "From " <>
        Money.to_string(Money.new(listing.from_price_cents, listing.from_price_currency || "USD"))

  def rating(%{rating_count: count}) when count in [nil, 0], do: nil
  def rating(listing), do: Decimal.to_string(listing.rating_avg)

  def reply_line(%{response_time_minutes: nil}), do: nil
  def reply_line(%{response_time_minutes: m}) when m < 60, do: "Replies in under an hour"
  def reply_line(%{response_time_minutes: m}) when m < 1440, do: "Replies within #{div(m, 60)}h"
  def reply_line(_listing), do: "Replies within a day"

  def travel_line(%{travels_worldwide: true}), do: "Travels worldwide"
  def travel_line(%{travel_radius_km: nil}), do: nil
  def travel_line(%{travel_radius_km: km}), do: "Travels up to #{km} km"

  def where(listing),
    do: [listing.city, listing.country_code] |> Enum.reject(&is_nil/1) |> Enum.join(", ")

  @doc "The path to a profile. Relative — `profile_url/1` is for canonicals."
  def profile_path(listing),
    do:
      ~p"/photographers/#{Directory.city_slug(listing.city || "elsewhere")}/#{listing.studio.slug}"

  @doc "Just the money, for places where the surrounding copy already says \"from\"."
  def price_only(%{from_price_cents: nil}), do: nil

  def price_only(listing),
    do: Money.to_string(Money.new(listing.from_price_cents, listing.from_price_currency || "USD"))

  @doc "A short badge for the card's cover, where there is room for four words."
  def reply_badge(%{response_time_minutes: nil}), do: nil
  def reply_badge(%{response_time_minutes: m}) when m < 60, do: "Replies in ~1h"
  def reply_badge(%{response_time_minutes: m}) when m < 1440, do: "Replies in ~#{div(m, 60)}h"
  def reply_badge(_listing), do: nil

  @doc "The deposit every package agrees on, or nil when they disagree."
  def deposit_percent([]), do: nil

  def deposit_percent(packages) do
    case packages |> Enum.map(& &1.deposit_percent) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [percent] -> percent
      _mixed -> nil
    end
  end

  def deposit_line([]), do: nil

  def deposit_line(packages) do
    case deposit_percent(packages) do
      nil -> nil
      percent -> "A #{percent}% deposit books the date. The balance is due before delivery."
    end
  end

  @doc """
  Five glyphs for a rating out of five.

  Rounded to the nearest whole star rather than drawn to the half, because a
  half star and an empty star are the same glyph in a system font — 4.9 came
  out looking like four and a half. The exact figure is printed beside it, so
  rounding the picture costs nothing.
  """
  def stars(nil), do: ""
  def stars(%Decimal{} = rating), do: rating |> Decimal.to_float() |> stars()

  def stars(rating) when is_number(rating) do
    filled = rating |> round() |> max(0) |> min(5)
    String.duplicate("★", filled) <> String.duplicate("☆", 5 - filled)
  end

  @doc "The shoot types this studio actually has work under, for the gallery tabs."
  def shoot_types(portfolio) do
    portfolio
    |> Enum.map(& &1.shoot_type)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def portfolio_for(portfolio, nil), do: portfolio
  def portfolio_for(portfolio, type), do: Enum.filter(portfolio, &(&1.shoot_type == type))

  def package_price(package),
    do: Money.to_string(Money.new(package.price_cents, package.price_currency || "USD"))

  def package_duration(%{duration_minutes: nil}), do: nil
  def package_duration(%{duration_minutes: m}) when m < 60, do: "#{m} min"
  def package_duration(%{duration_minutes: m}) when rem(m, 60) == 0, do: "#{div(m, 60)} hours"
  def package_duration(%{duration_minutes: m}), do: "#{Float.round(m / 60, 1)} hours"

  @doc "A review's one-line context: what it was, and when."
  def review_meta(review) do
    [review.shoot_type, review.published_at && Calendar.strftime(review.published_at, "%b %Y")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  def label_for(categories, key) do
    Enum.find_value(categories, key, fn c -> c.key == key && c.name end)
  end

  @doc "Whether any filter is active, for showing the clear-all control."
  def any_filters?(chosen) do
    chosen.styles != [] or chosen.languages != [] or
      chosen.rating not in [nil, ""] or chosen.budget not in [nil, ""] or
      chosen.what not in [nil, ""] or chosen.q not in [nil, ""] or
      chosen.price_min not in [nil, ""] or chosen.price_max not in [nil, ""] or
      chosen.where not in [nil, ""] or chosen.only_available
  end
end
