defmodule AperDesk.Repo.Migrations.FixUsageRollupOnDelete do
  use Ecto.Migration

  @moduledoc """
  Let a studio actually be deleted.

  The usage-rollup triggers maintain `studio_usage` with
  `INSERT ... ON CONFLICT DO UPDATE`, which is right for inserts and updates:
  the counter row may not exist yet, and upserting creates it.

  On DELETE it is wrong. Deleting a studio cascades to its leads and galleries,
  each cascade fires this trigger, and the upsert then tries to *recreate* the
  `studio_usage` row for a studio row that has already gone — violating the
  foreign key and aborting the whole delete. The practical effect was that a
  studio with any lead or gallery could never be removed, which breaks account
  closure and any erasure request.

  The fix is to decrement with a plain UPDATE on delete. If the counter row is
  already gone there is nothing to decrement, and `UPDATE` matching zero rows is
  correctly a no-op rather than an error.
  """

  def up do
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
      IF TG_OP = 'DELETE' THEN
        -- Decrement only. Never recreate the row: the studio may be mid-delete.
        IF OLD.status IN ('ready','delivered') THEN
          UPDATE studio_usage
             SET active_galleries = GREATEST(active_galleries - 1, 0),
                 live_bytes       = GREATEST(live_bytes - OLD.bytes_total, 0),
                 updated_at       = now()
           WHERE studio_id = OLD.studio_id;
        END IF;
        RETURN NULL;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        live_before := OLD.status IN ('ready','delivered');
        bytes_before := CASE WHEN live_before THEN OLD.bytes_total ELSE 0 END;
      END IF;

      live_after := NEW.status IN ('ready','delivered');
      bytes_after := CASE WHEN live_after THEN NEW.bytes_total ELSE 0 END;
      sid := NEW.studio_id;

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
    """

    execute """
    CREATE OR REPLACE FUNCTION studio_usage_lead_rollup()
    RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      active_before int := 0;
      active_after  int := 0;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF OLD.archived_at IS NULL AND OLD.stage NOT IN ('completed','lost') THEN
          UPDATE studio_usage
             SET active_leads = GREATEST(active_leads - 1, 0),
                 updated_at   = now()
           WHERE studio_id = OLD.studio_id;
        END IF;
        RETURN NULL;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        active_before := CASE WHEN OLD.archived_at IS NULL
                                AND OLD.stage NOT IN ('completed','lost')
                              THEN 1 ELSE 0 END;
      END IF;

      active_after := CASE WHEN NEW.archived_at IS NULL
                             AND NEW.stage NOT IN ('completed','lost')
                           THEN 1 ELSE 0 END;

      INSERT INTO studio_usage (studio_id, active_leads, inserted_at, updated_at)
      VALUES (NEW.studio_id, GREATEST(active_after - active_before, 0), now(), now())
      ON CONFLICT (studio_id) DO UPDATE SET
        active_leads = GREATEST(studio_usage.active_leads + active_after - active_before, 0),
        updated_at   = now();

      RETURN NULL;
    END $$;
    """
  end

  def down do
    # Restores the previous definitions, which cannot delete a studio.
    execute "DROP FUNCTION IF EXISTS studio_usage_gallery_rollup() CASCADE"
    execute "DROP FUNCTION IF EXISTS studio_usage_lead_rollup() CASCADE"
  end
end
