defmodule AperDesk.Galleries.Workers.ArchiveExpiredWorker do
  @moduledoc """
  Closes delivered galleries whose window has run out, and purges the ones
  whose recovery period has also passed.

  Storage is the plan's main pricing lever, so a gallery that never expires is
  a studio paying for nothing and a client holding a link that should have
  stopped working months ago.

  Archiving and purging are separate steps on purpose. Archiving frees the
  quota and stops the link; purging deletes the files and cannot be undone, and
  it only happens after the recovery window the studio was promised.
  """

  use Oban.Worker, queue: :galleries, max_attempts: 3

  alias AperDesk.Galleries
  alias AperDesk.Storage

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    archived = Galleries.archive_expired()
    purged = purge()

    {:ok, %{archived: length(archived), purged: purged}}
  end

  @doc """
  Delete the files behind galleries past their recovery window.

  The objects go first and the row is marked afterwards. A purged row whose
  files are still on disk is a studio being billed for storage it cannot see;
  a deleted row whose files remain is the same thing with no way to find them.
  """
  def purge(now \\ DateTime.utc_now()) do
    now
    |> Galleries.purgeable()
    |> Enum.reduce(0, fn gallery, count ->
      Storage.delete_prefix(Storage.gallery_prefix(gallery.studio_id, gallery.id))

      case Galleries.mark_purged(gallery) do
        {:ok, _gallery} -> count + 1
        _error -> count
      end
    end)
  end
end
