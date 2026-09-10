defmodule AperDesk.Repo.Migrations.CreateBilling do
  use Ecto.Migration

  @moduledoc """
  Plans, subscriptions, add-ons and the usage counters that enforce limits.

  Plan limits are data, not code. The previous system encoded them in a 500-line
  module, which meant grandfathering an existing customer onto old limits, or
  running a pricing experiment, required a deploy. Here a plan row carries its
  own limit map and a subscription pins the plan *version* it was sold, so a
  price change never silently re-prices existing customers.
  """

  def change do
    create table(:plans, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :key, :string, null: false
      add :version, :integer, null: false, default: 1
      add :name, :string, null: false
      add :tagline, :string
      add :monthly_price_cents, :bigint, null: false
      add :yearly_price_cents, :bigint, null: false
      add :currency, :string, null: false, default: "USD"
      add :extra_seat_price_cents, :bigint

      # Everything the app checks before allowing an action.
      add :limits, :map, null: false, default: %{}
      add :features, {:array, :string}, null: false, default: []

      add :position, :integer, null: false, default: 0
      add :public, :boolean, null: false, default: true
      add :stripe_monthly_price_id, :string
      add :stripe_yearly_price_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plans, [:key, :version])

    create table(:subscriptions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :plan_id, references(:plans, type: :uuid, on_delete: :restrict), null: false

      add :status, :string, null: false, default: "trialing"
      add :billing_period, :string, null: false, default: "monthly"
      add :seats, :integer, null: false, default: 1

      add :trial_ends_at, :utc_datetime_usec
      add :current_period_start, :utc_datetime_usec
      add :current_period_end, :utc_datetime_usec
      add :cancel_at_period_end, :boolean, null: false, default: false
      add :cancelled_at, :utc_datetime_usec

      # Data stays reachable for 30 days after cancellation, then is deleted.
      # Storing the date makes that promise auditable instead of tribal.
      add :data_retained_until, :utc_datetime_usec

      add :stripe_customer_id, :string
      add :stripe_subscription_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subscriptions, [:studio_id])

    create unique_index(:subscriptions, [:stripe_subscription_id],
             where: "stripe_subscription_id IS NOT NULL"
           )

    create constraint(:subscriptions, :subscriptions_status_is_known,
             check: "status IN ('trialing','active','past_due','paused','cancelled','expired')"
           )

    create table(:subscription_add_ons, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")

      add :subscription_id, references(:subscriptions, type: :uuid, on_delete: :delete_all),
        null: false

      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :quantity, :integer, null: false, default: 1
      add :unit_price_cents, :bigint, null: false
      add :currency, :string, null: false, default: "USD"

      # A gallery extension applies to one gallery; a storage block applies to
      # the studio. Same table, different target.
      add :target_id, :uuid
      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      add :stripe_item_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:subscription_add_ons, [:studio_id, :kind])

    create constraint(:subscription_add_ons, :subscription_add_ons_kind_is_known,
             check: "kind IN ('storage_block','gallery_extension','extra_seat')"
           )

    # Denormalised counters, one row per studio. Every limit check reads exactly
    # one row. Kept current by triggers and a nightly reconciliation job that
    # corrects drift rather than trusting the counters forever.
    create table(:studio_usage, primary_key: false) do
      add :studio_id,
          references(:studios, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :active_leads, :integer, null: false, default: 0
      add :active_galleries, :integer, null: false, default: 0
      add :live_bytes, :bigint, null: false, default: 0
      add :packages, :integer, null: false, default: 0
      add :forms, :integer, null: false, default: 0
      add :workflows, :integer, null: false, default: 0
      add :contract_templates, :integer, null: false, default: 0
      add :seats_used, :integer, null: false, default: 0
      add :emails_sent_this_period, :integer, null: false, default: 0
      add :reconciled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Stripe webhooks arrive at-least-once and out of order. Recording the event
    # id before acting is the only reliable way to stay idempotent.
    create table(:processed_webhook_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :provider, :string, null: false
      add :event_id, :string, null: false
      add :event_type, :string
      add :processed_at, :utc_datetime_usec, null: false
      add :payload, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:processed_webhook_events, [:provider, :event_id])

    # Keep active gallery and byte counters exact.
    execute """
            CREATE OR REPLACE FUNCTION studio_usage_gallery_rollup()
            RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              live_before boolean := false;
              live_after  boolean := false;
              bytes_before bigint := 0;
              bytes_after  bigint := 0;
              sid uuid;
            BEGIN
              IF TG_OP <> 'INSERT' THEN
                live_before := OLD.status IN ('ready','delivered');
                bytes_before := CASE WHEN live_before THEN OLD.bytes_total ELSE 0 END;
                sid := OLD.studio_id;
              END IF;

              IF TG_OP <> 'DELETE' THEN
                live_after := NEW.status IN ('ready','delivered');
                bytes_after := CASE WHEN live_after THEN NEW.bytes_total ELSE 0 END;
                sid := NEW.studio_id;
              END IF;

              INSERT INTO studio_usage (studio_id, active_galleries, live_bytes, inserted_at, updated_at)
              VALUES (
                sid,
                GREATEST(live_after::int - live_before::int, 0),
                GREATEST(bytes_after - bytes_before, 0),
                now(), now()
              )
              ON CONFLICT (studio_id) DO UPDATE SET
                active_galleries = GREATEST(studio_usage.active_galleries + live_after::int - live_before::int, 0),
                live_bytes       = GREATEST(studio_usage.live_bytes + bytes_after - bytes_before, 0),
                updated_at       = now();

              RETURN NULL;
            END $$;
            """,
            "DROP FUNCTION IF EXISTS studio_usage_gallery_rollup()"

    execute """
            CREATE TRIGGER studio_usage_gallery_rollup_trigger
            AFTER INSERT OR UPDATE OF status, bytes_total OR DELETE ON galleries
            FOR EACH ROW EXECUTE FUNCTION studio_usage_gallery_rollup()
            """,
            "DROP TRIGGER IF EXISTS studio_usage_gallery_rollup_trigger ON galleries"

    execute """
            CREATE OR REPLACE FUNCTION studio_usage_lead_rollup()
            RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              active_before int := 0;
              active_after  int := 0;
              sid uuid;
            BEGIN
              IF TG_OP <> 'INSERT' THEN
                active_before := CASE WHEN OLD.archived_at IS NULL
                                        AND OLD.stage NOT IN ('completed','lost')
                                      THEN 1 ELSE 0 END;
                sid := OLD.studio_id;
              END IF;

              IF TG_OP <> 'DELETE' THEN
                active_after := CASE WHEN NEW.archived_at IS NULL
                                       AND NEW.stage NOT IN ('completed','lost')
                                     THEN 1 ELSE 0 END;
                sid := NEW.studio_id;
              END IF;

              INSERT INTO studio_usage (studio_id, active_leads, inserted_at, updated_at)
              VALUES (sid, GREATEST(active_after - active_before, 0), now(), now())
              ON CONFLICT (studio_id) DO UPDATE SET
                active_leads = GREATEST(studio_usage.active_leads + active_after - active_before, 0),
                updated_at   = now();

              RETURN NULL;
            END $$;
            """,
            "DROP FUNCTION IF EXISTS studio_usage_lead_rollup()"

    execute """
            CREATE TRIGGER studio_usage_lead_rollup_trigger
            AFTER INSERT OR UPDATE OF stage, archived_at OR DELETE ON leads
            FOR EACH ROW EXECUTE FUNCTION studio_usage_lead_rollup()
            """,
            "DROP TRIGGER IF EXISTS studio_usage_lead_rollup_trigger ON leads"
  end
end
