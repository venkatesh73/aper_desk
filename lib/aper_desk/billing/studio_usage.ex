defmodule AperDesk.Billing.StudioUsage do
  @moduledoc """
  One row per studio holding every number a limit check needs.

  Enforcing a cap has to happen on the request that would exceed it, which means
  the check must be cheap enough to run on every upload and every lead create.
  Counting with `SUM()` over media rows would not survive a studio with 100k
  frames, so these counters are maintained by triggers (see the galleries and
  billing migrations) and read as a single primary-key lookup.

  Counters drift — a trigger bug, a bulk import, a restore. A nightly
  reconciliation recomputes the truth and stamps `reconciled_at`, so drift is
  bounded and visible rather than permanent and silent.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Billing.Plan

  # studio_id *is* the primary key here; there is no separate id column.
  @primary_key false

  schema "studio_usage" do
    belongs_to :studio, Studio, primary_key: true

    field :active_leads, :integer, default: 0
    field :active_galleries, :integer, default: 0
    field :live_bytes, :integer, default: 0
    field :packages, :integer, default: 0
    field :forms, :integer, default: 0
    field :workflows, :integer, default: 0
    field :contract_templates, :integer, default: 0
    field :seats_used, :integer, default: 0
    field :emails_sent_this_period, :integer, default: 0
    field :reconciled_at, :utc_datetime_usec

    timestamps()
  end

  # Maps a plan limit key to the counter that measures it.
  @limit_to_counter %{
    "active_leads" => :active_leads,
    "active_galleries" => :active_galleries,
    "storage_bytes" => :live_bytes,
    "packages" => :packages,
    "forms" => :forms,
    "workflows" => :workflows,
    "contract_templates" => :contract_templates,
    "seats" => :seats_used
  }

  def limit_to_counter, do: @limit_to_counter

  def changeset(usage, attrs) do
    usage
    |> cast(attrs, [
      :studio_id,
      :active_leads,
      :active_galleries,
      :live_bytes,
      :packages,
      :forms,
      :workflows,
      :contract_templates,
      :seats_used,
      :emails_sent_this_period,
      :reconciled_at
    ])
    |> validate_required([:studio_id])
    |> foreign_key_constraint(:studio_id)
  end

  @doc "Replace the counters with freshly computed truth."
  def reconcile_changeset(usage, counts) when is_map(counts) do
    usage
    |> changeset(Map.put(counts, :reconciled_at, DateTime.utc_now()))
  end

  @doc "Reset the per-period email counter at the start of a billing period."
  def reset_period_changeset(usage), do: change(usage, emails_sent_this_period: 0)

  @doc "The current value of the counter behind a plan limit key."
  def used(%__MODULE__{} = usage, limit_key) do
    case Map.fetch(@limit_to_counter, limit_key) do
      {:ok, counter} -> Map.get(usage, counter) || 0
      :error -> 0
    end
  end

  @doc """
  Whether one more of `limit_key` fits within `plan`.

  Returns `:ok` or `{:error, {:limit_reached, key, used, limit}}` — the caller
  needs the numbers to tell the studio what to upgrade to, so an unadorned
  `false` would just have to be re-derived at the call site.
  """
  def check(%__MODULE__{} = usage, %Plan{} = plan, limit_key, requested \\ 1) do
    used = used(usage, limit_key)

    case Plan.limit(plan, limit_key) do
      :unlimited ->
        :ok

      limit when used + requested <= limit ->
        :ok

      limit ->
        {:error, {:limit_reached, limit_key, used, limit}}
    end
  end

  @doc "How full a limit is, 0.0 to 1.0, or nil when unlimited. For the usage meters."
  def utilisation(%__MODULE__{} = usage, %Plan{} = plan, limit_key) do
    case Plan.limit(plan, limit_key) do
      :unlimited -> nil
      0 -> 1.0
      limit -> min(used(usage, limit_key) / limit, 1.0)
    end
  end

  @doc "Whether a counter has not been verified since `stale_after` seconds ago."
  def stale?(%__MODULE__{reconciled_at: nil}, _now, _stale_after), do: true

  def stale?(%__MODULE__{reconciled_at: at}, now, stale_after),
    do: DateTime.diff(now, at, :second) > stale_after
end
