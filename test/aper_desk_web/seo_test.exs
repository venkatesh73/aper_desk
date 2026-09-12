defmodule AperDeskWeb.SEOTest do
  @moduledoc """
  What each page tells a crawler.

  The indexable half of this is ordinary SEO. The other half is a privacy
  control: a `/g/<token>` in a search result is a couple's wedding
  photographs handed to strangers, and tokens leak the moment somebody pastes
  one into a public forum. So the noindex assertions here matter more than the
  index ones, and they are written per-route rather than in one loop so a new
  page that forgets is a named failure.
  """
  use AperDeskWeb.ConnCase, async: true

  import Ecto.Query
  import AperDesk.Fixtures

  alias AperDesk.{Accounts, Directory, Galleries, Repo, Sales}

  describe "pages that must never be indexed" do
    setup do
      %{studio: studio, scope: scope, user: user} = studio_fixture()
      plan_fixture(studio)
      %{studio: studio, scope: scope, user: user}
    end

    test "a client gallery link", %{conn: conn, scope: scope} do
      gallery = gallery_fixture(scope)
      {:ok, _} = Galleries.deliver_gallery(scope, gallery.id)
      {:ok, _share, token} = Galleries.share_gallery(scope, gallery.id, %{"label" => "Couple"})

      html = conn |> get(~p"/g/#{token}") |> html_response(200)

      assert html =~ ~s(name="robots" content="noindex, nofollow, noarchive")
      # noarchive as well: a cached copy is the same leak a week later, and
      # harder to withdraw.
      refute html =~ "index, follow"
    end

    test "a client quote link", %{conn: conn, scope: scope} do
      {:ok, quote} = Sales.create_quote(scope, %{"title" => "A wedding", "currency" => "USD"})
      {:ok, _quote, token} = Sales.send_quote(scope, quote.id)

      html = conn |> get(~p"/q/#{token}") |> html_response(200)
      assert html =~ ~s(content="noindex, nofollow, noarchive")
    end

    test "a studio's embedded enquiry form", %{conn: conn, scope: scope, studio: studio} do
      {:ok, form} = AperDesk.Comms.create_form(scope, %{"name" => "Enquiry", "slug" => "enquiry"})
      slug = Repo.reload!(studio).slug

      html = conn |> get(~p"/f/#{slug}/#{form.slug}") |> html_response(200)
      assert html =~ ~s(content="noindex, nofollow, noarchive")
    end

    test "the signed-in application", %{conn: conn, user: user, studio: studio} do
      {:ok, token, _} = Accounts.create_token(user, "session")

      html =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, token)
        |> Plug.Conn.put_session(:studio_id, studio.id)
        |> get(~p"/app")
        |> html_response(200)

      assert html =~ ~s(content="noindex, nofollow, noarchive")
    end

    test "sign-in, which is a door rather than a page", %{conn: conn} do
      html = conn |> get(~p"/sign-in") |> html_response(200)
      assert html =~ ~s(content="noindex, nofollow, noarchive")
    end
  end

  describe "the marketing page" do
    test "asks to be indexed, and says what it is", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(content="index, follow, max-image-preview:large")
      assert html =~ ~s(rel="canonical")
      assert html =~ ~s(property="og:title")
      assert html =~ ~s(property="og:description")
      assert html =~ "SoftwareApplication"
    end
  end

  describe "the directory" do
    setup %{conn: conn} do
      %{studio: studio, scope: scope} = studio_fixture(%{studio: %{name: "Aperture Lisboa"}})
      plan_fixture(studio)

      {:ok, _listing} =
        Directory.upsert_listing(scope, %{
          "headline" => "Documentary wedding photography",
          "bio" => "We shoot the day as it happens.",
          "city" => "Lisbon",
          "country_code" => "PT",
          "cover_url" => "https://example.com/cover.jpg",
          "from_price_cents" => 250_000,
          "from_price_currency" => "EUR"
        })

      {:ok, listing} = Directory.publish_listing(scope)
      %{conn: conn, studio: Repo.reload!(studio), scope: scope, listing: listing}
    end

    test "the hub links every city, so a crawler can reach them", %{conn: conn} do
      html = conn |> get(~p"/photographers") |> html_response(200)

      assert html =~ ~s(content="index, follow, max-image-preview:large")
      assert html =~ "Lisbon"
      assert html =~ ~s(href="/photographers/lisbon")
      assert html =~ "ItemList"
    end

    test "a city page is its own page, with its own canonical", %{conn: conn} do
      html = conn |> get(~p"/photographers/lisbon") |> html_response(200)

      # "wedding photographer in Lisbon" is a search somebody makes meaning to
      # book; "photographer" is not a search anybody wins.
      assert html =~ "Photographers in Lisbon"
      assert html =~ ~s(rel="canonical")
      assert html =~ ~s(/photographers/lisbon")
      assert html =~ "BreadcrumbList"
    end

    test "a studio profile carries LocalBusiness data, not just words", %{
      conn: conn,
      studio: studio
    } do
      html = conn |> get(~p"/photographers/lisbon/#{studio.slug}") |> html_response(200)

      assert html =~ "Aperture Lisboa"
      assert html =~ "ProfessionalService"
      assert html =~ "PostalAddress"
      assert html =~ "Lisbon"
      assert html =~ ~s(rel="canonical")
      assert html =~ ~s(property="og:type" content="profile")
    end

    test "an unpublished studio is a 404, not an empty page", %{conn: conn, scope: scope} do
      # A page that answers 200 stays in the index pointing at nothing.
      Repo.update_all(
        from(l in AperDesk.Directory.DirectoryListing),
        set: [published_at: nil]
      )

      assert scope

      assert_error_sent 404, fn ->
        get(conn, ~p"/photographers/lisbon/#{Repo.one!(Accounts.Studio).slug}")
      end
    end
  end

  describe "the sitemap" do
    test "lists the indexable pages and nothing private", %{conn: conn} do
      %{studio: studio, scope: scope} = studio_fixture()
      plan_fixture(studio)

      {:ok, _} =
        Directory.upsert_listing(scope, %{
          "headline" => "Documentary weddings in Porto",
          "bio" => "We photograph the day as it actually happened.",
          "city" => "Porto",
          "country_code" => "PT",
          "cover_url" => "https://example.com/cover.jpg"
        })

      {:ok, _} = Directory.publish_listing(scope)

      gallery = gallery_fixture(scope)
      {:ok, _} = Galleries.deliver_gallery(scope, gallery.id)
      {:ok, _share, token} = Galleries.share_gallery(scope, gallery.id, %{"label" => "C"})

      xml = conn |> get(~p"/sitemap.xml") |> response(200)

      assert xml =~ "<urlset"
      assert xml =~ "/photographers</loc>"
      assert xml =~ "/photographers/porto</loc>"
      assert xml =~ "/photographers/porto/#{Repo.reload!(studio).slug}</loc>"

      # A sitemap listing a private link would be handing the crawler the one
      # thing robots.txt is there to keep from it.
      refute xml =~ token
      refute xml =~ "/g/"
      refute xml =~ "/app"
    end

    test "is served as XML, because it is discarded otherwise", %{conn: conn} do
      conn = get(conn, ~p"/sitemap.xml")
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/xml"
    end
  end

  describe "structured data" do
    test "an aggregate rating is only claimed when reviews exist" do
      alias AperDeskWeb.SEO

      without = %AperDesk.Directory.DirectoryListing{rating_count: 0, city: "Lisbon"}
      studio = %AperDesk.Accounts.Studio{name: "Aperture"}

      schema = SEO.studio_schema(without, studio, "https://example.com")

      # Google issues manual actions for invented ratings, and a studio with no
      # reviews reads more honestly with none shown.
      refute Map.has_key?(schema, "aggregateRating")

      with_reviews = %{without | rating_count: 12, rating_avg: Decimal.new("4.8")}
      schema = SEO.studio_schema(with_reviews, studio, "https://example.com")

      assert schema["aggregateRating"]["ratingValue"] == "4.8"
      assert schema["aggregateRating"]["reviewCount"] == 12
    end

    test "empty values are dropped rather than claimed as empty" do
      alias AperDeskWeb.SEO

      schema =
        SEO.studio_schema(
          %AperDesk.Directory.DirectoryListing{rating_count: 0},
          %AperDesk.Accounts.Studio{name: "Aperture"},
          "https://example.com"
        )

      refute Map.has_key?(schema, "address")
      refute Map.has_key?(schema, "geo")
      refute Map.has_key?(schema, "image")
      assert schema["name"] == "Aperture"
    end
  end
end
