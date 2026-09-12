defmodule AperDesk.Billing.Workers.UsageRollupWorker do
  @moduledoc """
  Recomputes every studio's usage counters from the rows behind them.

  Triggers keep the counters current, and triggers can be bypassed — a bulk
  import with `session_replication_role`, a restore, a migration that rewrites
  a table. Counters trusted forever drift silently, and a drifted counter
  either blocks a paying studio or lets storage run away unbilled.

  This is also what expires quotes nobody answered, for the same reason: a
  quote that stays "sent" forever keeps showing up as money in play.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  import Ecto.Query

  alias AperDesk.Accounts
  alias AperDesk.Accounts.Studio
  alias AperDesk.Billing
  alias AperDesk.Repo
  alias AperDesk.Sales.Quote

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok,
     %{
       studios: reconcile_all(),
       quotes_expired: expire_quotes(),
       tokens_purged: Accounts.purge_expired_tokens()
     }}
  end

  @doc "One studio at a time, so one bad row cannot stop the rest reconciling."
  def reconcile_all do
    Studio
    |> where([s], is_nil(s.archived_at))
    |> select([s], s.id)
    |> Repo.all()
    |> Enum.count(fn studio_id ->
      match?({:ok, _}, Billing.reconcile_usage(studio_id))
    end)
  end

  @doc """
  Expire quotes past their validity date.

  Done in one statement across every studio rather than through
  `Sales.expire_quotes/2`, which takes a scope — this runs with no user behind
  it, and inventing an owner scope per studio to satisfy a permission check
  would be pretending at an authorisation that is not happening.
  """
  def expire_quotes(today \\ Date.utc_today()) do
    {count, _} =
      Repo.update_all(
        from(q in Quote,
          where:
            q.status in ^Quote.open_statuses() and not is_nil(q.valid_until) and
              q.valid_until < ^today
        ),
        set: [status: "expired", updated_at: DateTime.utc_now()]
      )

    count
  end
end
