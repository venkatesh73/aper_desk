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

  @doc "A URL a browser can fetch the object from."
  @callback url(key) :: String.t()

  def put(key, source_path, opts \\ []), do: adapter().put(key, source_path, opts)
  def delete(key), do: adapter().delete(key)
  def delete_prefix(prefix), do: adapter().delete_prefix(prefix)
  def url(nil), do: nil
  def url(key), do: adapter().url(key)

  @doc "The prefix holding everything for one gallery."
  def gallery_prefix(studio_id, gallery_id),
    do: "studios/#{studio_id}/galleries/#{gallery_id}"

  @doc """
  A fresh key for one upload, under its gallery's prefix.

  The extension is taken from the original name only after being checked
  against a short allowlist; anything else becomes `bin`. An extension is a
  hint to a webserver about what to serve, so an unrecognised one is not worth
  the risk of honouring.
  """
  @extensions ~w(jpg jpeg png gif webp avif heic heif tif tiff mp4 mov)

  def key_for(studio_id, gallery_id, filename) do
    ext =
      filename
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.downcase()
      |> then(&if &1 in @extensions, do: &1, else: "bin")

    "#{gallery_prefix(studio_id, gallery_id)}/#{Ecto.UUID.generate()}.#{ext}"
  end

  @doc "The extensions a key may carry, for the upload control's accept list."
  def extensions, do: @extensions

  @doc false
  def adapter, do: Keyword.fetch!(config(), :adapter)

  @doc false
  def config, do: Application.fetch_env!(:aper_desk, :storage)
end
