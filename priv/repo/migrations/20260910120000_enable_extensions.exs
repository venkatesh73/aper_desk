defmodule AperDesk.Repo.Migrations.EnableExtensions do
  use Ecto.Migration

  @moduledoc """
  Postgres extensions and shared helpers the rest of the schema depends on.

  `btree_gist` is the one that matters most: it lets a single exclusion
  constraint enforce "no crew member is in two places at once" inside the
  database, which is what makes clash detection trustworthy rather than a
  best-effort check in application code.
  """

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS citext"
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist"
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"

    # UUIDv7: time-ordered like a bigserial (so B-tree inserts stay at the right
    # edge and pagination by id is chronological) but unguessable, and safe for
    # the mobile client to mint offline. Postgres 18 ships uuidv7() natively;
    # this is the portable equivalent until we can rely on that.
    execute """
    CREATE OR REPLACE FUNCTION uuid_generate_v7()
    RETURNS uuid
    LANGUAGE plpgsql
    VOLATILE
    AS $$
    DECLARE
      unix_ts_ms bytea;
      uuid_bytes bytea;
    BEGIN
      unix_ts_ms := substring(int8send((extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);
      uuid_bytes := unix_ts_ms || gen_random_bytes(10);
      -- version 7
      uuid_bytes := set_byte(uuid_bytes, 6, (b'0111' || get_byte(uuid_bytes, 6)::bit(4))::bit(8)::int);
      -- RFC 4122 variant
      uuid_bytes := set_byte(uuid_bytes, 8, (b'10' || get_byte(uuid_bytes, 8)::bit(6))::bit(8)::int);
      RETURN encode(uuid_bytes, 'hex')::uuid;
    END
    $$;
    """

    # Amounts are always integer minor units + an ISO-4217 code. Storing money as
    # a float is the single most common source of reconciliation bugs in billing
    # systems, so the type system refuses to let us.
    execute """
    CREATE OR REPLACE FUNCTION assert_currency(code text)
    RETURNS boolean
    LANGUAGE sql
    IMMUTABLE
    AS $$ SELECT code ~ '^[A-Z]{3}$' $$;
    """
  end

  def down do
    execute "DROP FUNCTION IF EXISTS assert_currency(text)"
    execute "DROP FUNCTION IF EXISTS uuid_generate_v7()"
    execute "DROP EXTENSION IF EXISTS pg_trgm"
    execute "DROP EXTENSION IF EXISTS btree_gist"
    execute "DROP EXTENSION IF EXISTS citext"
  end
end
