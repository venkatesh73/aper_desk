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
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents, only: [empty: 1]

  alias AperDesk.Directory
  alias AperDesk.Money
  alias AperDeskWeb.SEO

  @impl true
  def mount(params, _session, socket) do
    {:ok, socket |> assign(:page_layout, false) |> load(socket.assigns.live_action, params)}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, load(socket, socket.assigns.live_action, params)}

  ## The hub

  defp load(socket, :index, params) do
    cities = Directory.list_cities()
    listings = Directory.search(search_opts(params))

    socket
    |> assign(cities: cities, listings: listings, city: nil, query: params["q"])
    |> assign(
      SEO.index(
        title: "Find a photographer",
        description:
          "Browse #{count_line(listings)} across #{length(cities)} #{if length(cities) == 1, do: "city", else: "cities"}. Compare work, prices and availability, then send one enquiry.",
        canonical: url(~p"/photographers"),
        schema: SEO.listing_page_schema(listings, url(~p"/photographers"), &profile_url/1)
      )
    )
  end

  ## One city

  defp load(socket, :city, %{"city" => slug} = params) do
    case Directory.find_city(slug) do
      nil ->
        socket
        |> put_flash(:error, "No photographers listed there yet.")
        |> push_navigate(to: ~p"/photographers")

      city ->
        listings = Directory.search(Keyword.put(search_opts(params), :city_slug, slug))
        where = [city.city, city.country_code] |> Enum.reject(&is_nil/1) |> Enum.join(", ")

        socket
        |> assign(cities: Directory.list_cities(), listings: listings, city: city, query: nil)
        |> assign(
          SEO.index(
            title: "Photographers in #{city.city}",
            # The description is what a searcher reads in the result, so it
            # says what is actually on the page rather than repeating the
            # title with keywords bolted on.
            description:
              "#{count_line(listings)} in #{where}. See their work, what they charge, and how quickly they reply — then enquire with one message.",
            canonical: url(~p"/photographers/#{slug}"),
            schema:
              SEO.breadcrumb_schema([
                {"Photographers", url(~p"/photographers")},
                {city.city, url(~p"/photographers/#{slug}")}
              ])
          )
        )
    end
  end

  ## One studio

  defp load(socket, :show, %{"city" => city_slug, "slug" => slug}) do
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
        |> assign(city_slug: city_slug)
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

  ## Internals

  defp search_opts(params) do
    []
    |> maybe_put(:query, params["q"])
    |> maybe_put(:city, params["city"])
    |> Keyword.put(:limit, 48)
  end

  defp maybe_put(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp count_line([]), do: "No photographers yet"
  defp count_line([_one]), do: "1 photographer"
  defp count_line(listings), do: "#{length(listings)} photographers"

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
end
