defmodule AperDeskWeb.GalleryLiveTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Galleries
  alias AperDesk.Storage

  defp sign_in(conn, user, studio) do
    {:ok, token, _} = Accounts.create_token(user, "session")

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:studio_id, studio.id)
  end

  setup %{conn: conn} do
    %{user: user, studio: studio, scope: scope} = studio_fixture()
    plan_fixture(studio)
    gallery = gallery_fixture(scope, %{"title" => "Anna and Ben"})

    %{
      conn: sign_in(conn, user, studio),
      scope: scope,
      user: user,
      studio: studio,
      gallery: gallery
    }
  end

  # A one-pixel PNG, so the upload path carries real bytes rather than a name.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  defp upload(view, name \\ "IMG_0001.png") do
    file =
      file_input(view, "#upload-form", :photos, [
        %{name: name, content: @png, type: "image/png", size: byte_size(@png)}
      ])

    render_upload(file, name)
    view |> form("#upload-form") |> render_submit()
  end

  describe "uploading" do
    test "stores the bytes and counts them against the gallery", %{
      conn: conn,
      scope: scope,
      gallery: gallery
    } do
      {:ok, view, html} = live(conn, ~p"/app/galleries/#{gallery}")
      assert html =~ "Nothing uploaded yet"

      upload(view)

      assert [media] = Galleries.list_media(scope, gallery.id)
      assert media.filename == "IMG_0001.png"
      assert media.byte_size == byte_size(@png)

      # The key is generated, never taken from the browser's filename.
      refute media.storage_key =~ "IMG_0001"
      assert File.read!(Path.join("tmp/test_uploads", media.storage_key)) == @png

      # The trigger keeps the gallery's own counters.
      {:ok, reloaded} = Galleries.fetch_gallery(scope, gallery.id)
      assert reloaded.media_count == 1
      assert reloaded.bytes_total == byte_size(@png)
    end

    test "the first photograph becomes the cover", %{conn: conn, scope: scope, gallery: gallery} do
      {:ok, view, _html} = live(conn, ~p"/app/galleries/#{gallery}")
      upload(view)

      [media] = Galleries.list_media(scope, gallery.id)
      {:ok, reloaded} = Galleries.fetch_gallery(scope, gallery.id)
      assert reloaded.cover_media_id == media.id
    end

    test "removing one takes the file with it", %{conn: conn, scope: scope, gallery: gallery} do
      {:ok, view, _html} = live(conn, ~p"/app/galleries/#{gallery}")
      upload(view)
      [media] = Galleries.list_media(scope, gallery.id)
      path = Path.join("tmp/test_uploads", media.storage_key)
      assert File.exists?(path)

      render_change(element(view, "select[phx-change='remove']"), %{"id" => media.id})

      assert Galleries.list_media(scope, gallery.id) == []
      refute File.exists?(path)
    end
  end

  describe "delivering and sharing" do
    test "delivering opens the plan's window", %{conn: conn, scope: scope, gallery: gallery} do
      {:ok, view, _html} = live(conn, ~p"/app/galleries/#{gallery}")

      render_click(element(view, "button[phx-click='deliver']"))

      {:ok, reloaded} = Galleries.fetch_gallery(scope, gallery.id)
      assert reloaded.status == "delivered"
      assert reloaded.expires_at
    end

    test "the share token is shown once and never again", %{conn: conn, gallery: gallery} do
      {:ok, view, _html} = live(conn, ~p"/app/galleries/#{gallery}")

      html = render_click(element(view, "button[phx-click='share']"))

      assert [url] = Regex.run(~r{https?://[^"]+/g/[A-Za-z0-9_-]+}, html)
      assert html =~ "cannot be shown again"

      # The token is not what is stored — only its hash is.
      token = url |> String.split("/g/") |> List.last()
      refute AperDesk.Repo.get_by(AperDesk.Galleries.GalleryShare, token_hash: token)
    end
  end

  describe "the client's link" do
    setup %{conn: conn, scope: scope, gallery: gallery} do
      {:ok, view, _html} = live(conn, ~p"/app/galleries/#{gallery}")
      upload(view)
      {:ok, _} = Galleries.deliver_gallery(scope, gallery.id)
      {:ok, _share, token} = Galleries.share_gallery(scope, gallery.id, %{"label" => "Couple"})
      %{token: token, media: hd(Galleries.list_media(scope, gallery.id))}
    end

    test "opens the gallery without a session at all", %{token: token} do
      {:ok, _view, html} = live(build_conn(), ~p"/g/#{token}")

      assert html =~ "Anna and Ben"
      assert html =~ "Your favourites"
    end

    test "a favourite is attributed to the link it came through", %{
      token: token,
      media: media,
      scope: scope,
      gallery: gallery
    } do
      {:ok, view, _html} = live(build_conn(), ~p"/g/#{token}")

      render_click(element(view, "button[phx-value-id='#{media.id}']"))

      assert {:ok, [selection]} = Galleries.list_selections(scope, gallery.id, "favourite")
      assert selection.media_id == media.id
      assert selection.share_id
    end

    test "tapping twice unfavourites rather than duplicating", %{
      token: token,
      media: media,
      scope: scope,
      gallery: gallery
    } do
      {:ok, view, _html} = live(build_conn(), ~p"/g/#{token}")

      render_click(element(view, "button[phx-value-id='#{media.id}']"))
      render_click(element(view, "button[phx-value-id='#{media.id}']"))

      assert {:ok, []} = Galleries.list_selections(scope, gallery.id, "favourite")
    end

    test "a revoked link says nothing about what was behind it", %{
      token: token,
      scope: scope,
      gallery: gallery
    } do
      {:ok, [share]} = Galleries.list_shares(scope, gallery.id)
      {:ok, _} = Galleries.revoke_share(scope, share.id)

      {:ok, _view, html} = live(build_conn(), ~p"/g/#{token}")

      assert html =~ "does not open anything"
      refute html =~ "Anna and Ben"
    end

    test "a token that never existed gets the same page", %{} do
      {:ok, _view, html} = live(build_conn(), ~p"/g/#{"made-up-token"}")
      assert html =~ "does not open anything"
    end
  end

  defp starve_storage(studio) do
    import Ecto.Query

    plan =
      AperDesk.Repo.one!(
        from p in AperDesk.Billing.Plan,
          join: s in AperDesk.Billing.Subscription,
          on: s.plan_id == p.id,
          where: s.studio_id == ^studio.id
      )

    plan
    |> Ecto.Changeset.change(%{limits: Map.put(plan.limits, "storage_bytes", 0)})
    |> AperDesk.Repo.update!()
  end

  describe "storage limits" do
    test "an upload past the cap is refused and leaves no orphan", %{
      conn: conn,
      scope: scope,
      studio: studio,
      gallery: gallery
    } do
      # No room at all on the plan the studio is already on: the next byte is
      # one too many. Swapping the limits beats adding a second subscription.
      starve_storage(studio)

      {:ok, view, _html} = live(conn, ~p"/app/galleries/#{gallery}")
      html = upload(view)

      assert html =~ "storage" or html =~ "plan is full"
      assert Galleries.list_media(scope, gallery.id) == []

      # Nothing left behind under the gallery's prefix.
      prefix = Path.join("tmp/test_uploads", Storage.gallery_prefix(studio.id, gallery.id))
      refute File.exists?(prefix) and File.ls!(prefix) != []
    end
  end
end
