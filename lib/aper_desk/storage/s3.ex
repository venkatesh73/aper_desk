defmodule AperDesk.Storage.S3 do
  @moduledoc """
  Any S3-compatible bucket — Cloudflare R2 by default.

  Uploads stream from the temporary file rather than being read into memory: a
  wedding gallery is thousands of frames, and a studio uploading a batch of
  50 MB raws would otherwise put all of them on the heap at once.
  """
  @behaviour AperDesk.Storage

  alias AperDesk.Storage

  @impl true
  def put(key, source_path, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    source_path
    |> ExAws.S3.Upload.stream_file()
    |> ExAws.S3.upload(bucket(), key, content_type: content_type)
    |> ExAws.request()
    |> case do
      {:ok, _response} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    bucket()
    |> ExAws.S3.delete_object(key)
    |> ExAws.request()
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_prefix(prefix) do
    bucket()
    |> ExAws.S3.list_objects(prefix: prefix)
    |> ExAws.stream!()
    |> Stream.map(& &1.key)
    |> Stream.chunk_every(1000)
    |> Enum.reduce_while(:ok, fn keys, :ok ->
      bucket()
      |> ExAws.S3.delete_all_objects(keys)
      |> ExAws.request()
      |> case do
        {:ok, _response} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def url(key), do: Path.join(public_base_url(), key)

  defp bucket, do: Keyword.fetch!(Storage.config(), :bucket)

  defp public_base_url, do: Keyword.fetch!(Storage.config(), :public_base_url)
end
