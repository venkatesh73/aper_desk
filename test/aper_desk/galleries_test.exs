defmodule AperDesk.GalleriesTest do
  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.Billing.StudioUsage
  alias AperDesk.Galleries
  alias AperDesk.Galleries.Gallery

  describe "storage limits" do
    setup do
      %{scope: scope, studio: studio} = studio_fixture()
      plan_fixture(studio, limits: %{"storage_bytes" => 10_000_000, "gallery_window_days" => 60})
      gallery = gallery_fixture(scope)
      {:ok, gallery} = Galleries.deliver_gallery(scope, gallery.id)
      %{scope: scope, studio: studio, gallery: gallery}
    end

    test "the byte counters are maintained by trigger", %{scope: scope, gallery: gallery} do
      {:ok, media} =
        Galleries.add_media(scope, gallery.id, %{
          "filename" => "a.jpg",
          "storage_key" => "k/a",
          "content_type" => "image/jpeg",
          "byte_size" => 5_000_000
        })

      reloaded = Repo.get!(Gallery, gallery.id)
      assert reloaded.media_count == 1
      assert reloaded.bytes_total == 5_000_000

      Repo.delete!(media)
      reloaded = Repo.get!(Gallery, gallery.id)
      assert reloaded.media_count == 0
      assert reloaded.bytes_total == 0
    end

    test "an upload over the cap is refused", %{scope: scope, gallery: gallery} do
      assert {:error, {:limit_reached, "storage_bytes", _, 10_000_000}} =
               Galleries.add_media(scope, gallery.id, %{
                 "filename" => "huge.jpg",
                 "storage_key" => "k/huge",
                 "content_type" => "image/jpeg",
                 "byte_size" => 20_000_000
               })
    end

    test "concurrent uploads cannot both take the last of the allowance", %{
      scope: scope,
      studio: studio,
      gallery: gallery
    } do
      {:ok, _} =
        Galleries.add_media(scope, gallery.id, %{
          "filename" => "big.jpg",
          "storage_key" => "k/big",
          "content_type" => "image/jpeg",
          "byte_size" => 9_000_000
        })

      results =
        1..5
        |> Task.async_stream(
          fn i ->
            Galleries.add_media(scope, gallery.id, %{
              "filename" => "x#{i}.jpg",
              "storage_key" => "k/x#{i}",
              "content_type" => "image/jpeg",
              "byte_size" => 900_000
            })
          end,
          max_concurrency: 5,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Repo.get!(StudioUsage, studio.id).live_bytes <= 10_000_000
    end
  end

  describe "delivery window" do
    test "comes from the plan and can be extended" do
      %{scope: scope, studio: studio} = studio_fixture()
      plan_fixture(studio, limits: %{"gallery_window_days" => 60, "storage_bytes" => 10_000_000})
      gallery = gallery_fixture(scope)

      {:ok, delivered} = Galleries.deliver_gallery(scope, gallery.id)
      assert Gallery.days_remaining(delivered, DateTime.utc_now()) in [59, 60]

      {:ok, extended} = Galleries.extend_gallery(scope, gallery.id, 30)
      assert Gallery.days_remaining(extended, DateTime.utc_now()) in [89, 90]
    end
  end

  describe "share links" do
    setup do
      %{scope: scope, studio: studio} = studio_fixture()
      plan_fixture(studio)
      gallery = gallery_fixture(scope)
      {:ok, gallery} = Galleries.deliver_gallery(scope, gallery.id)
      {:ok, share, token} = Galleries.share_gallery(scope, gallery.id, %{"label" => "The couple"})
      %{scope: scope, gallery: gallery, share: share, token: token}
    end

    test "only the hash is stored", %{share: share, token: token} do
      assert share.token_hash == :crypto.hash(:sha256, token)
      refute share.token_hash == token
    end

    test "a valid token opens the gallery and records the visit", %{
      gallery: gallery,
      token: token
    } do
      assert {:ok, opened, share} = Galleries.open_shared_gallery(token)
      assert opened.id == gallery.id
      assert share.view_count == 1
    end

    test "a revoked token stops working", %{scope: scope, share: share, token: token} do
      {:ok, _} = Galleries.revoke_share(scope, share.id)
      assert {:error, :revoked} = Galleries.open_shared_gallery(token)
    end

    test "an unknown token is refused" do
      assert {:error, :not_found} = Galleries.open_shared_gallery("not-a-real-token")
    end
  end

  describe "download limits" do
    test "cannot be exceeded" do
      %{scope: scope, studio: studio} = studio_fixture()
      plan_fixture(studio)
      gallery = gallery_fixture(scope, %{"title" => "Limited", "download_limit" => 2})

      assert {:ok, g} = Galleries.record_download(gallery)
      assert g.download_count == 1
      assert {:ok, g} = Galleries.record_download(g)
      assert g.download_count == 2
      assert {:error, :download_limit_reached} = Galleries.record_download(g)
    end
  end
end
