defmodule AperDeskWeb.MediaAccessTest do
  @moduledoc """
  Reaching the photographs themselves.

  Every control the studio has — revoking a share, the gallery's window
  closing, archiving it, turning downloads off, the code gate — used to stop
  the page and none of them stopped the bytes. Images were linked straight from
  the bucket, so a URL out of a referrer header or devtools kept working
  forever. The page tests all passed throughout.

  So these ask for the file, not the page.
  """
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures

  alias AperDesk.Accounts
  alias AperDesk.Galleries
  alias AperDesk.Repo

  setup %{conn: conn} do
    %{user: user, studio: studio, scope: scope} = studio_fixture()
    plan_fixture(studio)
    gallery = gallery_fixture(scope, %{"title" => "Anna and Ben"})

    {:ok, media} =
      Galleries.add_media(scope, gallery.id, %{
        "filename" => "IMG_0001.jpg",
        "storage_key" => "studios/#{studio.id}/galleries/#{gallery.id}/frame.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 2048
      })

    {:ok, share, token} =
      Galleries.share_gallery(scope, gallery.id, %{"label" => "The couple"})

    %{
      conn: conn,
      user: user,
      studio: studio,
      scope: scope,
      gallery: gallery,
      media: media,
      share: share,
      token: token
    }
  end

  defp sign_in(conn, user, studio) do
    {:ok, token, _} = Accounts.create_token(user, "session")

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:studio_id, studio.id)
  end

  describe "a live share link" do
    test "serves the file", %{conn: conn, token: token, media: media} do
      conn = get(conn, ~p"/g/#{token}/media/#{media.id}/preview")
      assert conn.status in [301, 302, 307]
    end

    test "never hands back a bucket path the browser could keep", %{
      conn: conn,
      token: token,
      media: media
    } do
      conn = get(conn, ~p"/g/#{token}/media/#{media.id}/preview")

      # Whatever it redirects to is the adapter's business; what matters is
      # that the caching layer is told this is one person's URL.
      assert get_resp_header(conn, "cache-control") == ["private, max-age=60"]
    end
  end

  describe "after the studio revokes the link" do
    test "the photographs stop, not just the page", %{
      conn: conn,
      scope: scope,
      share: share,
      token: token,
      media: media
    } do
      # It works first, so the 404 afterwards is the revocation and not a
      # route that never worked.
      assert get(conn, ~p"/g/#{token}/media/#{media.id}/preview").status in [301, 302, 307]

      {:ok, _share} = Galleries.revoke_share(scope, share.id)

      assert get(conn, ~p"/g/#{token}/media/#{media.id}/preview").status == 404
    end
  end

  describe "after the gallery is archived" do
    test "the file is gone too", %{conn: conn, gallery: gallery, token: token, media: media} do
      gallery
      |> Ecto.Changeset.change(status: "archived")
      |> Repo.update!()

      assert get(conn, ~p"/g/#{token}/media/#{media.id}/preview").status == 404
    end
  end

  describe "the code gate" do
    test "covers the files as well as the page", %{
      conn: conn,
      scope: scope,
      gallery: gallery,
      token: token,
      media: media
    } do
      {:ok, _gallery} = Galleries.update_gallery(scope, gallery.id, %{"requires_otp" => true})

      # No unlock in this session, so there is nothing to serve. A gate that
      # only covers the HTML is not a gate.
      assert get(conn, ~p"/g/#{token}/media/#{media.id}/preview").status == 404
    end
  end

  describe "downloads that the studio turned off" do
    test "cannot be had by asking for the original directly", %{
      conn: conn,
      scope: scope,
      gallery: gallery,
      token: token,
      media: media
    } do
      {:ok, _gallery} =
        Galleries.update_gallery(scope, gallery.id, %{"download_enabled" => false})

      assert get(conn, ~p"/g/#{token}/media/#{media.id}/original").status == 404

      # The preview still works — the client can still look, just not keep.
      assert get(conn, ~p"/g/#{token}/media/#{media.id}/preview").status in [301, 302, 307]
    end
  end

  describe "another studio's file" do
    test "is not reachable through a valid link of your own", %{conn: conn, token: token} do
      %{studio: other_studio, scope: other_scope} = studio_fixture()
      plan_fixture(other_studio)
      other_gallery = gallery_fixture(other_scope, %{"title" => "Someone else"})

      {:ok, other_media} =
        Galleries.add_media(other_scope, other_gallery.id, %{
          "filename" => "theirs.jpg",
          "storage_key" => "studios/#{other_studio.id}/galleries/#{other_gallery.id}/x.jpg",
          "content_type" => "image/jpeg",
          "byte_size" => 1024
        })

      assert get(conn, ~p"/g/#{token}/media/#{other_media.id}/preview").status == 404
    end
  end

  describe "the studio's own door" do
    test "serves the file to someone signed in", %{
      conn: conn,
      user: user,
      studio: studio,
      media: media
    } do
      conn = conn |> sign_in(user, studio) |> get(~p"/app/media/#{media.id}/thumb")
      assert conn.status in [301, 302, 307]
    end

    test "is not a way around tenancy", %{conn: conn, media: media} do
      %{user: other_user, studio: other_studio} = studio_fixture()
      plan_fixture(other_studio)

      conn =
        conn |> sign_in(other_user, other_studio) |> get(~p"/app/media/#{media.id}/thumb")

      assert conn.status == 404
    end

    test "turns a signed-out request away", %{conn: conn, media: media} do
      conn = get(conn, ~p"/app/media/#{media.id}/thumb")

      # RequireAuth sends it to sign-in; what must not happen is the file.
      assert redirected_to(conn) =~ "/sign-in"
    end
  end
end
