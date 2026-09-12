defmodule AperDeskWeb.DirectorySearchTest do
  @moduledoc """
  The consumer half: searching, filtering and one studio's profile.

  The context could already search, rank and match on distance, and the page
  in front of it offered two text boxes. These drive the controls a searcher
  actually gets — and one of them, unticking a filter, did not work at all
  when the sidebar merged its payload into the previous filters: an unchecked
  box sends nothing, so a filter could be added and never removed.
  """
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AperDesk.Directory
  alias AperDesk.Repo

  defp listing(attrs) do
    %{studio: studio, scope: scope} =
      studio_fixture(%{studio: %{name: attrs.name, base_currency: "EUR"}})

    plan_fixture(studio)

    {:ok, _} =
      Directory.upsert_listing(scope, %{
        "headline" => attrs[:headline] || "Documentary wedding photography, quietly",
        "bio" => attrs[:bio] || "We shoot the day as it happens.",
        "city" => attrs.city,
        "country_code" => "PT",
        "cover_url" => "https://example.com/cover.jpg",
        "from_price_cents" => attrs.price,
        "from_price_currency" => "EUR",
        "languages" => attrs[:languages] || ["English"],
        "response_time_minutes" => attrs[:response] || 120
      })

    {:ok, published} = Directory.publish_listing(scope)

    Repo.update_all(
      from(l in AperDesk.Directory.DirectoryListing, where: l.studio_id == ^studio.id),
      set: [rating_avg: Decimal.new(attrs[:rating] || "4.5"), rating_count: attrs[:reviews] || 10]
    )

    if keys = attrs[:categories] do
      ids =
        Directory.list_categories()
        |> Enum.filter(&(&1.key in keys))
        |> Enum.map(& &1.id)

      {:ok, _} = Directory.set_categories(scope, ids)
    end

    %{studio: studio, scope: scope, listing: Repo.reload!(published)}
  end

  setup %{conn: conn} do
    categories_fixture()

    a =
      listing(%{
        name: "Aperture Lisboa",
        city: "Lisbon",
        price: 540_000,
        categories: ["wedding", "portrait"],
        rating: "4.9",
        reviews: 31,
        languages: ["English", "Portuguese"]
      })

    b =
      listing(%{
        name: "Porto Film",
        city: "Porto",
        price: 320_000,
        categories: ["wedding"],
        rating: "4.2",
        reviews: 8,
        languages: ["Portuguese"],
        response: 30
      })

    c =
      listing(%{
        name: "Studio Retrato",
        city: "Lisbon",
        price: 900_000,
        categories: ["portrait"],
        rating: "4.8",
        reviews: 12,
        languages: ["English"],
        response: 600
      })

    %{conn: conn, a: a, b: b, c: c}
  end

  describe "the search page" do
    test "shows every published studio as a card with what it shoots", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/photographers")

      assert html =~ "3 photographers"
      assert html =~ "Aperture Lisboa"
      assert html =~ "Porto Film"

      # The card's tags are the studio's categories. The headline went there
      # first and overflowed the card, which is a sentence in a chip.
      assert html =~ "Wedding"
      assert html =~ "Portrait"
    end

    test "counts beside each filter say what choosing it would give", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/photographers")

      assert html =~ "Style"
      assert html =~ "Languages"
      assert html =~ "Price for a full day"
      assert html =~ "4.5 and up"
    end
  end

  describe "filtering" do
    test "by style narrows the results", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/photographers")

      html = render_change(form(view, "form[phx-submit=filter]"), %{"style" => ["portrait"]})

      assert html =~ "2 photographers"
      assert html =~ "Aperture Lisboa"
      assert html =~ "Studio Retrato"
      refute html =~ "Porto Film"
    end

    test "unticking a filter removes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/photographers")
      form = form(view, "form[phx-submit=filter]")

      assert render_change(form, %{"style" => ["portrait"]}) =~ "2 photographers"

      # The form sends no `style` key at all when nothing is ticked. A handler
      # that merged this into the previous filters would leave it applied.
      assert render_change(form, %{"style" => []}) =~ "3 photographers"
    end

    test "by rating, and it combines with style", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/photographers")
      form = form(view, "form[phx-submit=filter]")

      assert render_change(form, %{"rating" => "4.5"}) =~ "2 photographers"

      html = render_change(form, %{"rating" => "4.5", "style" => ["wedding"]})
      assert html =~ "1 photographer"
      assert html =~ "Aperture Lisboa"
    end

    test "by language", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/photographers")

      html = render_change(form(view, "form[phx-submit=filter]"), %{"lang" => ["Portuguese"]})

      assert html =~ "2 photographers"
      refute html =~ "Studio Retrato"
    end

    test "by price, in whole units rather than cents", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/photographers")

      html =
        render_change(form(view, "form[phx-submit=filter]"), %{
          "price_min" => "4000",
          "price_max" => "6000"
        })

      assert html =~ "1 photographer"
      assert html =~ "Aperture Lisboa"
    end

    test "the filters end up in the URL, so the search can be sent to someone",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/photographers")

      render_change(form(view, "form[phx-submit=filter]"), %{"style" => ["portrait"]})

      # No `sort=recommended` riding along: the default is what the bare URL
      # already means, and carrying it makes a second address for one page.
      assert_patch(view, "/photographers?style[]=portrait")
    end

    test "a filtered view is not offered to a crawler", %{conn: conn} do
      # Three near-identical pages competing with the city page they were cut
      # from is worse for the city page than not being indexed at all.
      html = conn |> get(~p"/photographers/lisbon?style[]=portrait") |> html_response(200)
      assert html =~ "noindex"

      plain = conn |> get(~p"/photographers/lisbon") |> html_response(200)
      assert plain =~ ~s(content="index, follow, max-image-preview:large")
    end
  end

  describe "sorting" do
    test "by price puts the cheapest first and studios without one last", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/photographers?sort=price")

      assert position(html, "Porto Film") < position(html, "Aperture Lisboa")
      assert position(html, "Aperture Lisboa") < position(html, "Studio Retrato")
    end

    test "by fastest reply", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/photographers?sort=response")

      assert position(html, "Porto Film") < position(html, "Studio Retrato")
    end
  end

  describe "a city page" do
    test "shows only that city and says so", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/photographers/lisbon")

      assert html =~ "2 photographers"
      assert html =~ "Aperture Lisboa"
      refute html =~ "Porto Film"
    end
  end

  describe "a studio's profile" do
    setup %{a: a} do
      {:ok, package} =
        AperDesk.Catalog.create_package(a.scope, %{
          "name" => "Full day",
          "price_cents" => 540_000,
          "price_currency" => "EUR",
          "duration_minutes" => 600,
          "edited_image_count" => 600,
          "public" => true,
          "items" => [%{"label" => "Second photographer", "included" => true, "position" => 0}]
        })

      {:ok, private} =
        AperDesk.Catalog.create_package(a.scope, %{
          "name" => "Negotiated corporate rate",
          "price_cents" => 100_000,
          "price_currency" => "EUR",
          "public" => false
        })

      %{package: package, private: private}
    end

    test "shows the packages, what they include, and the deposit", %{conn: conn, a: a} do
      {:ok, _view, html} = live(conn, ~p"/photographers/lisbon/#{a.studio.slug}")

      assert html =~ "Full day"
      assert html =~ "600+ edited images"
      assert html =~ "Second photographer"
      assert html =~ "deposit books the date"
    end

    test "never shows a package the studio kept private", %{conn: conn, a: a} do
      {:ok, _view, html} = live(conn, ~p"/photographers/lisbon/#{a.studio.slug}")

      # A rate negotiated for one client is not this studio's public price.
      refute html =~ "Negotiated corporate rate"
    end

    test "links the enquiry at the studio's own form when they have one", %{conn: conn, a: a} do
      {:ok, form} =
        AperDesk.Comms.create_form(a.scope, %{"name" => "Wedding enquiry", "fields" => %{}})

      {:ok, _view, html} = live(conn, ~p"/photographers/lisbon/#{a.studio.slug}")

      assert html =~ ~s(href="/f/#{a.studio.slug}/#{form.slug}")
    end

    test "says so rather than linking nowhere when they have not", %{conn: conn, a: a} do
      {:ok, _view, html} = live(conn, ~p"/photographers/lisbon/#{a.studio.slug}")

      assert html =~ "has not opened an enquiry form yet"
    end
  end

  defp position(html, needle) do
    case :binary.match(html, needle) do
      {at, _length} -> at
      :nomatch -> flunk("#{needle} is not on the page")
    end
  end
end
