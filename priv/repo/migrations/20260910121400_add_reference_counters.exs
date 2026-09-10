defmodule AperDesk.Repo.Migrations.AddReferenceCounters do
  use Ecto.Migration

  @moduledoc """
  Human-facing reference numbers for leads, jobs, quotes, contracts, invoices
  and payouts.

  Six tables declare `reference` NOT NULL with a per-studio unique index, but
  nothing produced the value, so every insert on those tables failed. This adds
  the missing piece.

  It is done with a BEFORE INSERT trigger rather than in application code for
  the same reason the gallery byte counters are: a reference that application
  code is trusted to remember is a reference that some code path eventually
  forgets. Doing it in the database means every insert path — a context, a
  seed, a CSV import, a psql session — gets a correct number, and the sequence
  cannot skip because a transaction rolled back after allocating.

  Numbering is per studio and per kind, so each studio sees its own invoices
  running 1, 2, 3 rather than sharing a global sequence with every other studio
  on the platform — which would leak the platform's total volume to anyone
  holding two invoices.

  A dedicated counter table is used instead of a Postgres sequence because
  sequences are not transactional (a rollback leaves a gap) and cannot be
  created per studio without unbounded DDL.
  """

  def up do
    create table(:reference_counters, primary_key: false) do
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), primary_key: true

      add :kind, :string, primary_key: true
      add :next_value, :bigint, null: false, default: 1
    end

    # Allocate the next number for (studio, kind) and return it formatted.
    #
    # The INSERT ... ON CONFLICT DO UPDATE is what makes this safe under
    # concurrency: the row is locked for the duration of the statement, so two
    # simultaneous inserts for the same studio cannot receive the same number.
    execute """
            CREATE OR REPLACE FUNCTION allocate_reference(sid uuid, ref_kind text, prefix text)
            RETURNS text LANGUAGE plpgsql AS $$
            DECLARE
              seq bigint;
            BEGIN
              INSERT INTO reference_counters (studio_id, kind, next_value)
              VALUES (sid, ref_kind, 2)
              ON CONFLICT (studio_id, kind) DO UPDATE
                SET next_value = reference_counters.next_value + 1
              RETURNING CASE
                WHEN reference_counters.next_value = 2 THEN 1
                ELSE reference_counters.next_value - 1
              END INTO seq;

              RETURN prefix || '-' || LPAD(seq::text, 4, '0');
            END $$;
            """,
            "DROP FUNCTION IF EXISTS allocate_reference(uuid, text, text)"

    # One trigger function for all six tables. The prefix comes from the
    # trigger argument, so adding a seventh referenced table is one CREATE
    # TRIGGER rather than another function.
    execute """
            CREATE OR REPLACE FUNCTION set_reference()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF NEW.reference IS NULL THEN
                NEW.reference := allocate_reference(NEW.studio_id, TG_TABLE_NAME, TG_ARGV[0]);
              END IF;
              RETURN NEW;
            END $$;
            """,
            "DROP FUNCTION IF EXISTS set_reference()"

    for {table, prefix} <- [
          {"leads", "LEA"},
          {"jobs", "JOB"},
          {"quotes", "QUO"},
          {"contracts", "CON"},
          {"invoices", "INV"},
          {"payouts", "PAY"}
        ] do
      execute """
              CREATE TRIGGER set_reference_trigger
              BEFORE INSERT ON #{table}
              FOR EACH ROW EXECUTE FUNCTION set_reference('#{prefix}')
              """,
              "DROP TRIGGER IF EXISTS set_reference_trigger ON #{table}"
    end
  end

  def down do
    for table <- ~w(leads jobs quotes contracts invoices payouts) do
      execute "DROP TRIGGER IF EXISTS set_reference_trigger ON #{table}"
    end

    execute "DROP FUNCTION IF EXISTS set_reference()"
    execute "DROP FUNCTION IF EXISTS allocate_reference(uuid, text, text)"
    drop table(:reference_counters)
  end
end
