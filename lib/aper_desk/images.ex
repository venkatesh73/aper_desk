defmodule AperDesk.Images do
  @moduledoc """
  Thumbnails, previews and watermarks.

  A gallery row carries three keys: the original the photographer uploaded, a
  `thumb` for grids and a `preview` for the lightbox and the client's page. The
  original is never what a browser is sent. A wedding gallery is several
  hundred frames, and serving the originals as a contact sheet asks a couple on
  a phone to download several gigabytes to decide which ones they like.

  Sizes are longest-edge bounds rather than crops: the photographer framed it,
  and a square crop for a grid throws away that decision. Everything is written
  as JPEG whatever arrived, because a 40 MB TIFF and an HEIC that Firefox will
  not open are both unhelpful to a browser.

  Video gets a poster frame from `ffmpeg` if it is installed, and nothing if it
  is not — see `poster/1`. A missing poster leaves the keys nil and the callers
  fall back to the original, which is worse but not broken.
  """

  require Logger

  @thumb_edge 480
  @preview_edge 1800
  @thumb_quality 72
  @preview_quality 84

  @doc """
  Derive a thumbnail and a preview from a local file.

  `opts` takes `:watermark` — a string to burn into the preview, or nil. Only
  the preview is watermarked: a 480px thumbnail is too small to be worth taking
  and too small to carry legible text.

  Returns `{:ok, %{thumb: path, preview: path, width: w, height: h}}` with
  paths under `dir`, or `{:error, reason}`. Nothing is uploaded here.
  """
  def derive(source_path, dir, opts \\ []) do
    with {:ok, image} <- open(source_path),
         {:ok, thumb} <- write_thumb(image, dir),
         {:ok, preview} <- write_preview(image, dir, Keyword.get(opts, :watermark)) do
      {:ok,
       %{
         thumb: thumb,
         preview: preview,
         width: Image.width(image),
         height: Image.height(image)
       }}
    end
  end

  @doc """
  Whether this content type is something we can derive from at all.

  Checked before work is queued rather than after it fails, so a PDF dropped
  into a gallery does not become a retrying job.
  """
  def derivable?(content_type) when is_binary(content_type) do
    String.starts_with?(content_type, "image/") or String.starts_with?(content_type, "video/")
  end

  def derivable?(_content_type), do: false

  def video?(content_type) when is_binary(content_type),
    do: String.starts_with?(content_type, "video/")

  def video?(_content_type), do: false

  @doc """
  A still from one second into a video, written under `dir`.

  One second rather than zero: the first frame of a clip is very often black,
  and a grid of black rectangles is indistinguishable from a broken grid.
  """
  def poster(source_path, dir) do
    case System.find_executable("ffmpeg") do
      nil ->
        {:error, :no_ffmpeg}

      ffmpeg ->
        out = Path.join(dir, "poster.jpg")

        args = [
          "-loglevel",
          "error",
          "-ss",
          "1",
          "-i",
          source_path,
          "-frames:v",
          "1",
          "-q:v",
          "3",
          "-y",
          out
        ]

        case System.cmd(ffmpeg, args, stderr_to_stdout: true) do
          {_output, 0} -> if File.exists?(out), do: {:ok, out}, else: {:error, :no_frame}
          {output, code} -> {:error, {:ffmpeg, code, String.slice(output, 0, 300)}}
        end
    end
  end

  ## Internals

  defp open(path) do
    case Image.open(path, access: :random) do
      {:ok, image} -> {:ok, flatten(image)}
      {:error, reason} -> {:error, reason}
    end
  end

  # An alpha channel in a JPEG is not a thing, and vips will refuse rather than
  # guess. A PNG with transparency therefore gets white behind it, which is what
  # a browser would have shown anyway.
  defp flatten(image) do
    if Image.has_alpha?(image) do
      case Image.flatten(image, background_colour: :white) do
        {:ok, flat} -> flat
        _error -> image
      end
    else
      image
    end
  end

  defp write_thumb(image, dir) do
    resize_to(image, @thumb_edge, Path.join(dir, "thumb.jpg"), @thumb_quality)
  end

  defp write_preview(image, dir, watermark) do
    with {:ok, resized} <- resize(image, @preview_edge),
         {:ok, marked} <- apply_watermark(resized, watermark) do
      write(marked, Path.join(dir, "preview.jpg"), @preview_quality)
    end
  end

  defp resize_to(image, edge, path, quality) do
    with {:ok, resized} <- resize(image, edge) do
      write(resized, path, quality)
    end
  end

  # Never upscale. A phone snapshot that is already smaller than the preview
  # bound gets interpolated into a bigger, softer, heavier file otherwise.
  defp resize(image, edge) do
    longest = max(Image.width(image), Image.height(image))

    if longest <= edge do
      {:ok, image}
    else
      Image.thumbnail(image, edge, resize: :down)
    end
  end

  defp write(image, path, quality) do
    case Image.write(image, path, quality: quality, strip_metadata: true) do
      {:ok, _image} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_watermark(image, nil), do: {:ok, image}
  defp apply_watermark(image, ""), do: {:ok, image}

  defp apply_watermark(image, text) do
    # Sized against the frame rather than fixed, so it reads the same on a
    # 1800px preview as on a 900px one.
    size = max(round(Image.width(image) / 36), 14)

    with {:ok, label} <-
           Image.Text.text(text,
             font_size: size,
             font: "Helvetica",
             text_fill_color: "white",
             padding: round(size / 2)
           ),
         {:ok, composed} <-
           Image.compose(image, label, x: :right, y: :bottom, blend_mode: :over) do
      {:ok, composed}
    else
      {:error, reason} ->
        # A gallery that delivers unmarked is better than a gallery that fails
        # to deliver. The studio is told on the settings panel either way.
        Logger.warning("watermark failed, delivering unmarked: #{inspect(reason)}")
        {:ok, image}
    end
  end
end
