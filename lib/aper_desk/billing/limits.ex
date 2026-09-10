defmodule AperDesk.Billing.Limits do
  @moduledoc """
  Enforcing plan limits without a race.

  The naive version — read the counter, compare it to the plan, then insert —
  is wrong under concurrency. Two uploads that each see 9 galleries against a
  cap of 10 will both pass the check and both insert, and the studio ends up
  with 11. The window between the read and the write is small, but "small" is
  not "absent", and the two requests that hit it are exactly the ones a busy
  studio generates.

  So the check takes a row lock. `ensure_headroom/4` must be called inside the
  same transaction as the insert it guards; it does `SELECT ... FOR UPDATE` on
  the studio's usage row, which serialises every limit check for that studio
  and holds until the transaction commits. The second request blocks, then
  re-reads the counter the first one moved, and is correctly refused.

  Locking per studio rather than globally means one busy studio never blocks
  another — the contention is confined to the tenant that caused it.
  """

  import Ecto.Query

  alias AperDesk.Billing.{Plan, StudioUsage, Subscription}
  alias AperDesk.Scope

  @doc """
  Reserve headroom for `requested` more of `limit_key`, or refuse.

  Returns `:ok`, or `{:error, {:limit_reached, key, used, limit}}` carrying the
  numbers the UI needs to say "you are on Basic, which allows 10".

  MUST be called inside a transaction. Outside one the lock is released
  immediately and the guarantee is gone.
  """
  def ensure_headroom(repo, %Scope{} = scope, limit_key, requested \\ 1) do
    studio_id = Scope.studio_id(Scope.require_studio!(scope))

    with {:ok, plan} <- fetch_plan(repo, studio_id),
         usage <- lock_usage(repo, studio_id) do
      used = StudioUsage.used(usage, limit_key)

      case Plan.limit(plan, limit_key) do
        :unlimited -> :ok
        limit when used + requested <= limit -> :ok
        limit -> {:error, {:limit_reached, limit_key, used, limit}}
      end
    end
  end

  @doc """
  Storage is checked in bytes against the plan allowance plus any add-on blocks,
  so it does not go through `ensure_headroom/4`.
  """
  def ensure_storage(repo, %Scope{} = scope, bytes) when is_integer(bytes) and bytes >= 0 do
    studio_id = Scope.studio_id(Scope.require_studio!(scope))

    with {:ok, subscription} <- fetch_subscription(repo, studio_id),
         usage <- lock_usage(repo, studio_id) do
      case Subscription.storage_limit_bytes(subscription, DateTime.utc_now()) do
        :unlimited ->
          :ok

        limit when usage.live_bytes + bytes <= limit ->
          :ok

        limit ->
          {:error, {:limit_reached, "storage_bytes", usage.live_bytes, limit}}
      end
    end
  end

  @doc """
  The delivery window the studio's plan allows, in days.

  Read from the plan rather than hard-coded so the 60/180/365-day tiers are a
  pricing decision rather than a code change.
  """
  def gallery_window_days(repo, %Scope{} = scope) do
    case fetch_plan(repo, Scope.studio_id(scope)) do
      {:ok, plan} ->
        case Plan.limit(plan, "gallery_window_days") do
          :unlimited -> 3650
          days -> days
        end

      _ ->
        30
    end
  end

  @doc "Whether the plan the studio is on includes `feature`."
  def feature?(repo, %Scope{} = scope, feature) do
    case fetch_plan(repo, Scope.studio_id(scope)) do
      {:ok, plan} -> Plan.feature?(plan, feature)
      _ -> false
    end
  end

  @doc """
  Whether the studio may use the product at all.

  Checked at the session boundary rather than on every write: a lapsed
  subscription should stop someone signing in, not fail their save halfway
  through a form.
  """
  def entitled?(repo, studio_id) do
    case fetch_subscription(repo, studio_id) do
      {:ok, subscription} -> Subscription.entitled?(subscription, DateTime.utc_now())
      _ -> false
    end
  end

  @doc """
  Recompute a studio's counters from the underlying rows.

  Triggers keep the counters current, but triggers can be bypassed — a bulk
  import with `session_replication_role`, a restore, a migration that rewrites
  a table. Counters that are trusted forever drift silently; recomputing them
  nightly bounds the error and stamps when it was last verified.
  """
  def reconcile(repo, studio_id) do
    counts = %{
      active_leads: count_active_leads(repo, studio_id),
      active_galleries: count_active_galleries(repo, studio_id),
      live_bytes: sum_live_bytes(repo, studio_id),
      packages: count_where(repo, "packages", studio_id, "archived_at IS NULL"),
      forms: count_where(repo, "lead_capture_forms", studio_id, "active"),
      workflows: count_where(repo, "workflows", studio_id, "archived_at IS NULL"),
      contract_templates:
        count_where(repo, "contract_templates", studio_id, "archived_at IS NULL"),
      seats_used: count_where(repo, "memberships", studio_id, "status = 'active'")
    }

    usage = repo.get(StudioUsage, studio_id) || %StudioUsage{studio_id: studio_id}

    usage
    |> StudioUsage.reconcile_changeset(counts)
    |> repo.insert_or_update()
  end

  ## Internals

  # Ensures the row exists, then locks it. The insert is `ON CONFLICT DO
  # NOTHING` because the trigger may have created it already, and two callers
  # racing to create it must not both fail.
  defp lock_usage(repo, studio_id) do
    repo.query!(
      """
      INSERT INTO studio_usage (studio_id, inserted_at, updated_at)
      VALUES ($1, now(), now())
      ON CONFLICT (studio_id) DO NOTHING
      """,
      [dump_uuid(studio_id)]
    )

    from(u in StudioUsage, where: u.studio_id == ^studio_id, lock: "FOR UPDATE")
    |> repo.one!()
  end

  defp fetch_plan(repo, studio_id) do
    query =
      from s in Subscription,
        where: s.studio_id == ^studio_id,
        join: p in assoc(s, :plan),
        select: p

    case repo.one(query) do
      nil -> {:error, :no_subscription}
      plan -> {:ok, plan}
    end
  end

  defp fetch_subscription(repo, studio_id) do
    query =
      from s in Subscription,
        where: s.studio_id == ^studio_id,
        preload: [:plan, :add_ons]

    case repo.one(query) do
      nil -> {:error, :no_subscription}
      subscription -> {:ok, subscription}
    end
  end

  defp count_active_leads(repo, studio_id) do
    scalar(
      repo,
      """
      SELECT count(*) FROM leads
       WHERE studio_id = $1 AND archived_at IS NULL
         AND stage NOT IN ('completed','lost')
      """,
      studio_id
    )
  end

  defp count_active_galleries(repo, studio_id) do
    scalar(
      repo,
      """
      SELECT count(*) FROM galleries
       WHERE studio_id = $1 AND status IN ('ready','delivered')
      """,
      studio_id
    )
  end

  defp sum_live_bytes(repo, studio_id) do
    scalar(
      repo,
      """
      SELECT COALESCE(sum(bytes_total), 0) FROM galleries
       WHERE studio_id = $1 AND status IN ('ready','delivered')
      """,
      studio_id
    )
  end

  defp count_where(repo, table, studio_id, condition) do
    scalar(repo, "SELECT count(*) FROM #{table} WHERE studio_id = $1 AND #{condition}", studio_id)
  end

  # Postgres returns count() as bigint and sum() as numeric, and the driver
  # gives the latter back as a Decimal. Coerced here so the counters stay
  # integers all the way through — a Decimal reaching the changeset fails the
  # cast, which is how this was found.
  defp scalar(repo, sql, studio_id) do
    %{rows: [[value]]} = repo.query!(sql, [dump_uuid(studio_id)])

    case value do
      %Decimal{} = decimal -> Decimal.to_integer(decimal)
      integer when is_integer(integer) -> integer
      nil -> 0
    end
  end

  defp dump_uuid(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, binary} -> binary
      :error -> raise ArgumentError, "expected a UUID, got #{inspect(id)}"
    end
  end
end
