defmodule AperDesk.Storage do
  @moduledoc """
  Where uploaded files actually live.

  Two adapters: `AperDesk.Storage.Local` writes under `priv/static/uploads` for
  development, and `AperDesk.Storage.S3` talks to any S3-compatible bucket in
  production. The gallery code knows only about keys and URLs, so moving a
  studio between the two is a config change rather than a migration.

  Keys are generated here and never derived from what the client uploaded. A
  filename arrives from a browser, which means it can contain `..`, a leading
  slash, a null byte, or four hundred characters of unicode — none of which
  belong in a path. The original is kept as a *label* on the media row, for
  showing back to the photographer and naming the file on the way out again.

  The layout puts every key for one gallery under a single prefix:

      studios/<studio_id>/galleries/<gallery_id>/<uuid>.<ext>

  which is what lets the purge worker delete a gallery's storage with one
  prefix operation instead of walking rows it may no longer have.
  """

  @type key :: String.t()

  @doc "Write `source_path` at `key`. Returns the key back on success."
  @callback put(key, source_path :: Path.t(), opts :: keyword) :: {:ok, key} | {:error, term}

  @doc "Remove one object. Absent is success — the caller wanted it gone."
  @callback delete(key) :: :ok | {:error, term}

  @doc "Remove everything under a prefix, for purging a whole gallery."
  @callback delete_prefix(prefix :: String.t()) :: :ok | {:error, term}

  @doc """
  Copy an object down to a local path, for work that needs the bytes.

  Deriving a thumbnail from a 40 MB frame means having the frame. Streamed to
  disk rather than returned as a binary: a worker holding several originals in
  memory at once is how a box runs out of it.
  """
  @callback fetch(key, dest_path :: Path.t()) :: {:ok, Path.t()} | {:error, term}

  @doc "A URL a browser can fetch the object from."
  @callback url(key) :: String.t()

  @doc """
  A URL that stops working.

  Gallery objects are reached through this and never by their bucket path, so
  a link the studio revoked cannot be fetched afterwards by anyone who kept the
  image URL. `expires_in` is seconds.
  """
  @callback signed_url(key, expires_in :: pos_integer) :: {:ok, String.t()} | {:error, term}

  def put(key, source_path, opts \\ []), do: adapter().put(key, source_path, opts)
  def delete(key), do: adapter().delete(key)
  def delete_prefix(prefix), do: adapter().delete_prefix(prefix)
  def fetch(key, dest_path), do: adapter().fetch(key, dest_path)
  def signed_url(key, expires_in \\ 300), do: adapter().signed_url(key, expires_in)
  def url(nil), do: nil
  def url(key), do: adapter().url(key)

  @doc "The prefix holding everything for one gallery."
  def gallery_prefix(studio_id, gallery_id),
    do: "studios/#{studio_id}/galleries/#{gallery_id}"

  @doc "The prefix holding one package's sample work."
  def package_prefix(studio_id, package_id),
    do: "studios/#{studio_id}/packages/#{package_id}"

  @image_extensions ~w(jpg jpeg png gif webp avif heic heif tif tiff)
  # `m4v` is deliberately absent: the `mime` library has no type for it, and
  # `allow_upload` refuses an extension it cannot map. It is a niche container
  # anyway — mp4, mov and webm are what studios actually hand over.
  @video_extensions ~w(mp4 mov webm)

  @doc """
  A fresh key for one upload, under its gallery's prefix.

  See `key_in/2`; this is the gallery-shaped call, kept because it is what
  every gallery upload already says.
  """
  def key_for(studio_id, gallery_id, filename),
    do: key_in(gallery_prefix(studio_id, gallery_id), filename)

  @doc """
  A fresh key under `prefix`, keeping only a recognised extension.

  The extension is taken from the original name only after being checked
  against a short allowlist; anything else becomes `bin`. An extension is a
  hint to a webserver about what to serve, so an unrecognised one is not worth
  the risk of honouring — and the rest of the name is discarded entirely, since
  a browser will happily send `../../etc/passwd`.
  """
  def key_in(prefix, filename) do
    "#{prefix}/#{Ecto.UUID.generate()}.#{extension_of(filename)}"
  end

  @doc "The extensions a key may carry, for the upload control's accept list."
  def extensions, do: @image_extensions ++ @video_extensions

  @doc "Just the still-image extensions."
  def image_extensions, do: @image_extensions

  @doc "Just the moving-image extensions."
  def video_extensions, do: @video_extensions

  @doc """
  Whether a file is a still or a moving image.

  Decided from the content type first and the extension second. The content
  type is what the browser claims and the extension is what the name claims;
  neither is trustworthy on its own, but agreeing on "video" from either is
  enough to hold the file to the video size limit, which is the larger one — so
  a wrong answer here is never the one that lets an oversized file through.
  """
  def kind_of(content_type, filename \\ "")

  def kind_of("image/" <> _, _filename), do: "image"
  def kind_of("video/" <> _, _filename), do: "video"

  def kind_of(_content_type, filename) do
    case extension_of(filename) do
      ext when ext in @image_extensions -> "image"
      ext when ext in @video_extensions -> "video"
      _ -> "other"
    end
  end

  defp extension_of(filename) do
    filename
    |> to_string()
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()
    |> then(&if &1 in (@image_extensions ++ @video_extensions), do: &1, else: "bin")
  end

  @doc false
  def adapter, do: Keyword.fetch!(config(), :adapter)

  @doc false
  def config, do: Application.fetch_env!(:aper_desk, :storage)
end
