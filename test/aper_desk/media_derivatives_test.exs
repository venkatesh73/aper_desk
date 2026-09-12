defmodule AperDesk.MediaDerivativesTest do
  @moduledoc """
  Thumbnails and previews.

  `thumb_key` and `preview_key` were on the schema from the first migration,
  `processed_changeset/2` was written to record them, and every reader already
  had a `thumb_key || storage_key` fallback. Nothing ever wrote them, so the
  fallback was not a fallback — it was the only path, and every thumbnail in
  every grid was the full-resolution original.

  These assert on the bytes rather than on the keys being non-nil, because a
  derivative that is the same size as its original is the bug wearing a key.
  """
  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.Galleries
  alias AperDesk.Galleries.GalleryMedia
  alias AperDesk.Galleries.Workers.DeriveMediaWorker
  alias AperDesk.Repo
  alias AperDesk.Storage

  setup do
    %{studio: studio, scope: scope} = studio_fixture()
    plan_fixture(studio)
    gallery = gallery_fixture(scope, %{"title" => "Anna and Ben"})
    %{scope: scope, studio: studio, gallery: gallery}
  end

  # A real photograph-shaped JPEG rather than a 1px PNG: resizing a single
  # pixel proves the code ran, not that it made anything smaller.
  defp upload_frame(scope, gallery, opts \\ []) do
    width = Keyword.get(opts, :width, 3000)
    height = Keyword.get(opts, :height, 2000)

    dir = Path.join(System.tmp_dir!(), "frame-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "IMG_0001.jpg")

    {:ok, image} = Image.new(width, height, color: [90, 120, 160])
    {:ok, _} = Image.write(image, path)

    key = Storage.key_for(gallery.studio_id, gallery.id, "IMG_0001.jpg")
    {:ok, key} = Storage.put(key, path, content_type: "image/jpeg")

    {:ok, media} =
      Galleries.add_media(scope, gallery.id, %{
        "filename" => "IMG_0001.jpg",
        "storage_key" => key,
        "content_type" => "image/jpeg",
        "byte_size" => File.stat!(path).size
      })

    File.rm_rf(dir)
    Repo.get!(GalleryMedia, media.id)
  end

  defp bytes(key) do
    dir = Path.join(System.tmp_dir!(), "read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, path} = Storage.fetch(key, Path.join(dir, "f"))
    size = File.stat!(path).size
    File.rm_rf(dir)
    size
  end

  describe "uploading a frame" do
    test "derives a thumbnail and a preview", %{scope: scope, gallery: gallery} do
      media = upload_frame(scope, gallery)

      assert media.thumb_key
      assert media.preview_key
      assert media.processing_state == "ready"

      # The dimensions the photographer's file actually had.
      assert media.width == 3000
      assert media.height == 2000
    end

    test "the thumbnail is a fraction of the original, not a copy of it", %{
      scope: scope,
      gallery: gallery
    } do
      media = upload_frame(scope, gallery)

      original = bytes(media.storage_key)
      thumb = bytes(media.thumb_key)
      preview = bytes(media.preview_key)

      # The whole point. A grid of forty of these used to be forty originals.
      assert thumb < original / 4,
             "thumb #{thumb} is not meaningfully smaller than original #{original}"

      assert preview < original
      assert thumb < preview
    end

    test "a frame smaller than the preview bound is not upscaled", %{
      scope: scope,
      gallery: gallery
    } do
      media = upload_frame(scope, gallery, width: 800, height: 600)

      dir = Path.join(System.tmp_dir!(), "small-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      {:ok, path} = Storage.fetch(media.preview_key, Path.join(dir, "p.jpg"))
      {:ok, preview} = Image.open(path)

      assert Image.width(preview) == 800
      File.rm_rf(dir)
    end
  end

  describe "the watermark" do
    test "changes the preview when the gallery asks for one", %{
      scope: scope,
      gallery: gallery
    } do
      plain = upload_frame(scope, gallery)
      plain_preview = bytes(plain.preview_key)

      {:ok, _gallery} =
        Galleries.update_gallery(scope, gallery.id, %{"watermark_enabled" => true})

      marked = Repo.get!(GalleryMedia, plain.id)

      # Re-derived under a fresh key, so the client's browser cannot serve the
      # unmarked one out of its cache.
      assert marked.preview_key != plain.preview_key
      assert bytes(marked.preview_key) != plain_preview

      # And the old object is gone rather than left lying in the bucket.
      assert {:error, _reason} =
               Storage.fetch(plain.preview_key, Path.join(System.tmp_dir!(), "x"))
    end

    test "turning it back off restores an unmarked preview", %{scope: scope, gallery: gallery} do
      media = upload_frame(scope, gallery)
      {:ok, _} = Galleries.update_gallery(scope, gallery.id, %{"watermark_enabled" => true})
      marked = Repo.get!(GalleryMedia, media.id)

      {:ok, _} = Galleries.update_gallery(scope, gallery.id, %{"watermark_enabled" => false})
      unmarked = Repo.get!(GalleryMedia, media.id)

      assert unmarked.preview_key != marked.preview_key
    end

    test "a setting that did not change does not rebuild anything", %{
      scope: scope,
      gallery: gallery
    } do
      media = upload_frame(scope, gallery)

      {:ok, _} = Galleries.update_gallery(scope, gallery.id, %{"title" => "Anna and Ben Jr"})

      assert Repo.get!(GalleryMedia, media.id).preview_key == media.preview_key
    end
  end

  describe "what cannot be derived" do
    test "is marked failed rather than retried forever", %{scope: scope, gallery: gallery} do
      key = Storage.key_for(gallery.studio_id, gallery.id, "notes.bin")

      path = Path.join(System.tmp_dir!(), "notes-#{System.unique_integer([:positive])}.bin")
      File.write!(path, "not an image")
      {:ok, key} = Storage.put(key, path, content_type: "application/octet-stream")

      {:ok, media} =
        Galleries.add_media(scope, gallery.id, %{
          "filename" => "notes.bin",
          "storage_key" => key,
          "content_type" => "application/octet-stream",
          "byte_size" => 12
        })

      media = Repo.get!(GalleryMedia, media.id)
      assert media.processing_state == "failed"
      assert is_nil(media.thumb_key)

      File.rm(path)
    end

    test "a job for a row that was deleted is not an error", %{scope: scope, gallery: gallery} do
      media = upload_frame(scope, gallery)
      {:ok, _} = Galleries.remove_media(scope, media.id)

      assert {:ok, :gone} =
               DeriveMediaWorker.perform(%Oban.Job{args: %{"media_id" => media.id}})
    end
  end
end
