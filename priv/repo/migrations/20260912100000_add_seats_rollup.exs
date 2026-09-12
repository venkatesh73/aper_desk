defmodule AperDesk.Repo.Migrations.AddSeatsRollup do
  use Ecto.Migration

  @moduledoc """
  Keep `seats_used` current.

  Every other counter on `studio_usage` is maintained by a trigger; seats were
  not. `Limits.reconcile/2` counts them, but reconciliation is a nightly sweep
  that bounds drift — it is not the thing that makes a counter true between
  runs. The result was a seat count that stayed at whatever it was when the
  studio was created: the settings screen reported "0 of 3" to a studio with
  six people in it, and `ensure_headroom(_, _, "seats")` would have let a
  studio on a one-seat plan add as many as it liked.

  Counts memberships with `status = 'active'`, which is what `reconcile/2`
  counts, so the trigger and the sweep cannot disagree.

  DELETE decrements with a plain UPDATE rather than an upsert, for the reason
  spelled out in `FixUsageRollupOnDelete`: deleting a studio cascades to its
  memberships, and recreating the counter row for a studio that has already
  gone violates the foreign key and aborts the delete.
  """

  def up do
    execute """
    CREATE OR REPLACE FUNCTION studio_usage_seat_rollup()
    RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      active_before int := 0;
      active_after  int := 0;
      sid uuid;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF OLD.status = 'active' THEN
          UPDATE studio_usage
             SET seats_used = GREATEST(seats_used - 1, 0),
                 updated_at = now()
           WHERE studio_id = OLD.studio_id;
        END IF;
        RETURN NULL;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        active_before := CASE WHEN OLD.status = 'active' THEN 1 ELSE 0 END;
      END IF;

      active_after := CASE WHEN NEW.status = 'active' THEN 1 ELSE 0 END;
      sid := NEW.studio_id;

      INSERT INTO studio_usage (studio_id, seats_used, inserted_at, updated_at)
      VALUES (sid, GREATEST(active_after - active_before, 0), now(), now())
      ON CONFLICT (studio_id) DO UPDATE SET
        seats_used = GREATEST(studio_usage.seats_used + active_after - active_before, 0),
        updated_at = now();

      RETURN NULL;
    END $$;
    """

    execute """
    CREATE TRIGGER studio_usage_seat_rollup_trigger
    AFTER INSERT OR UPDATE OF status OR DELETE ON memberships
    FOR EACH ROW EXECUTE FUNCTION studio_usage_seat_rollup()
    """

    # Every existing studio has been counting wrong since it was created.
    execute """
    UPDATE studio_usage u
       SET seats_used = (
             SELECT count(*) FROM memberships m
              WHERE m.studio_id = u.studio_id AND m.status = 'active'
           ),
           updated_at = now()
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS studio_usage_seat_rollup_trigger ON memberships"
    execute "DROP FUNCTION IF EXISTS studio_usage_seat_rollup()"
  end
end
