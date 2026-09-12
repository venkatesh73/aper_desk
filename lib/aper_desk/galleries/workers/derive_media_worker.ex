defmodule AperDesk.Galleries.Workers.DeriveMediaWorker do
  @moduledoc """
  Builds the thumbnail and preview for one uploaded file.

  Off the request because a photographer hands over four hundred frames at a
  time, and resizing each one inside the upload would make the browser wait on
  work it does not need the answer to. Until the job lands the row's derivative
  keys are nil and every caller falls back to the original — correct, just
  heavy, which is the state the whole gallery used to be in permanently.

  The job is enqueued in the same transaction as the media row, so a frame
  cannot exist without work scheduled to process it, and a rolled-back upload
  cannot leave a job pointing at a row that was never committed.

  Re-running is safe and is how a watermark toggle takes effect: new
  derivatives are written under fresh keys and the old ones are deleted only
  after the row points at the new ones. A crash in between costs two orphaned
  objects, which is cheaper than a gallery of broken images.
  """

  use Oban.Worker, queue: :galleries, max_attempts: 3

  require Logger

  alias AperDesk.Galleries.GalleryMedia
  alias AperDesk.Images
  alias AperDesk.Repo
  alias AperDesk.Storage

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_id" => media_id}}) do
    case Repo.get(GalleryMedia, media_id) |> Repo.preload(:gallery) do
      nil ->
        # Deleted between enqueue and run. Nothing to do and nothing wrong.
        {:ok, :gone}

      media ->
        if Images.derivable?(media.content_type) do
          derive(media)
        else
          mark(media, "failed")
          {:ok, :not_derivable}
        end
    end
  end

  defp derive(media) do
    dir = Path.join(System.tmp_dir!(), "derive-#{media.id}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      mark(media, "processing")

      with {:ok, source} <- original(media, dir),
           {:ok, still} <- still_from(source, media.content_type, dir),
           {:ok, output} <- Images.derive(still, dir, watermark: watermark(media)),
           {:ok, keys} <- upload(media, output) do
        old = [media.thumb_key, media.preview_key]

        {:ok, updated} =
          media
          |> GalleryMedia.processed_changeset(
            Map.merge(keys, %{width: output.width, height: output.height})
          )
          |> Repo.update()

        # Only now that the row points elsewhere.
        for key <- Enum.reject(old, &is_nil/1), do: Storage.delete(key)

        {:ok, %{media_id: updated.id, thumb: updated.thumb_key}}
      else
        {:error, :no_ffmpeg} ->
          # A video in a deployment with no ffmpeg. Honest rather than
          # retried: the next three attempts would find it just as absent.
          mark(media, "failed")
          {:ok, :no_video_support}

        {:error, reason} ->
          mark(media, "failed")
          {:error, reason}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp original(media, dir) do
    Storage.fetch(media.storage_key, Path.join(dir, "original"))
  end

  # A video cannot be resized into a thumbnail, so a frame out of it is what
  # gets derived from. Stills pass straight through.
  defp still_from(source, content_type, dir) do
    if Images.video?(content_type), do: Images.poster(source, dir), else: {:ok, source}
  end

  defp watermark(media) do
    if media.gallery.watermark_enabled do
      media.gallery.studio_id && studio_name(media)
    end
  end

  defp studio_name(media) do
    case Repo.get(AperDesk.Accounts.Studio, media.studio_id) do
      nil -> nil
      studio -> studio.name
    end
  end

  defp upload(media, output) do
    prefix = Storage.gallery_prefix(media.studio_id, media.gallery_id)

    with {:ok, thumb} <- put(prefix, output.thumb, "thumb"),
         {:ok, preview} <- put(prefix, output.preview, "preview") do
      {:ok, %{thumb_key: thumb, preview_key: preview}}
    end
  end

  defp put(prefix, path, label) do
    key = Storage.key_in("#{prefix}/#{label}", "x.jpg")
    Storage.put(key, path, content_type: "image/jpeg")
  end

  defp mark(media, state) do
    media
    |> Ecto.Changeset.change(processing_state: state)
    |> Repo.update()
  end

  @doc "Queue derivation for one media row, as part of `multi`."
  def enqueue(media_id), do: new(%{media_id: media_id})
end
