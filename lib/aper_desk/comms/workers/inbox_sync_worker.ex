defmodule AperDesk.Comms.Workers.InboxSyncWorker do
  @moduledoc """
  Polls connected mailboxes for enquiries that arrived by email.

  A studio's leads mostly arrive as email, so a lead pipeline that only knows
  about web forms knows about a fraction of the work.

  The IMAP and Gmail fetching is not built yet, and this worker deliberately
  does not pretend otherwise: it walks the connected accounts, records that it
  looked, and returns how many it would have polled. That keeps the crontab
  honest — the schedule, the queue and the failure handling are real and
  exercised, and the day a fetcher is written it has somewhere to land.
  """

  use Oban.Worker, queue: :inbound, max_attempts: 3

  import Ecto.Query

  alias AperDesk.Comms.EmailAccount
  alias AperDesk.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Anything not disconnected is worth polling. `error` is included on
    # purpose: an account that failed to sync yesterday is exactly the one that
    # needs trying again, and excluding it would make the failure permanent.
    accounts =
      EmailAccount
      |> where([a], a.sync_state != "disconnected")
      |> Repo.all()

    now = DateTime.utc_now()

    for account <- accounts do
      Repo.update_all(
        from(a in EmailAccount, where: a.id == ^account.id),
        set: [last_synced_at: now, updated_at: now]
      )
    end

    {:ok, %{accounts: length(accounts), fetched: 0}}
  end
end
