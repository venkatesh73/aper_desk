defmodule AperDesk.Repo.Migrations.CreateGalleries do
  use Ecto.Migration

  @moduledoc """
  Client delivery galleries.

  Storage accounting is the subtle part. The plan caps are on *live* storage,
  so the number that matters is a moving sum that has to be correct at upload
  time to reject an over-cap upload. Recomputing it with a SUM() over every
  media row on each upload does not scale, so `galleries.bytes_total` is kept
  by trigger and rolled up into `studio_usage` (in the billing migration).
  """

  def change do
    create table(:galleries, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :job_id, references(:jobs, type: :uuid, on_delete: :nilify_all)
      add :contact_id, references(:contacts, type: :uuid, on_delete: :nilify_all)
      add :owner_id, references(:users, type: :uuid, on_delete: :nilify_all)

      add :title, :string, null: false
      add :slug, :citext, null: false
      add :description, :text
      add :cover_media_id, :uuid

      add :status, :string, null: false, default: "draft"

      # Delivery window: the plan sets the length, the gallery stores the actual
      # date so an extension add-on can push one gallery without touching plan
      # logic.
      add :delivered_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec
      add :purge_after, :utc_datetime_usec

      add :download_enabled, :boolean, null: false, default: true
      add :download_limit, :integer
      add :download_count, :integer, null: false, default: 0
      add :selection_limit, :integer
      add :watermark_enabled, :boolean, null: false, default: false
      add :show_studio_badge, :boolean, null: false, default: true

      add :password_hash, :string
      add :requires_otp, :boolean, null: false, default: false

      add :media_count, :integer, null: false, default: 0
      add :bytes_total, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:galleries, [:studio_id, :slug])
    create index(:galleries, [:studio_id, :status])
    create index(:galleries, [:job_id])

    create index(:galleries, [:expires_at],
             where: "status = 'delivered' AND archived_at IS NULL",
             name: :galleries_pending_expiry
           )

    create constraint(:galleries, :galleries_status_is_known,
             check: "status IN ('draft','ready','delivered','archived','purged')"
           )

    create table(:gallery_media, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :gallery_id, references(:galleries, type: :uuid, on_delete: :delete_all), null: false
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false

      add :filename, :string, null: false
      add :storage_key, :string, null: false
      add :thumb_key, :string
      add :preview_key, :string
      add :content_type, :string, null: false
      add :byte_size, :bigint, null: false
      add :width, :integer
      add :height, :integer

      # Content hash: the same frame delivered to two galleries is stored once.
      add :checksum, :string
      add :album, :string
      add :position, :integer, null: false, default: 0
      add :favourite_count, :integer, null: false, default: 0
      add :selected_count, :integer, null: false, default: 0
      add :processing_state, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gallery_media, [:gallery_id, :position])
    create index(:gallery_media, [:studio_id])
    create index(:gallery_media, [:checksum], where: "checksum IS NOT NULL")

    # Named recipients. A wedding gallery gets shared with the couple, both sets
    # of parents and the venue, each with their own link and their own limits.
    create table(:gallery_shares, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :gallery_id, references(:galleries, type: :uuid, on_delete: :delete_all), null: false
      add :label, :string, null: false
      add :email, :citext
      add :token_hash, :binary, null: false
      add :can_download, :boolean, null: false, default: true
      add :can_select, :boolean, null: false, default: true
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :view_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gallery_shares, [:token_hash])
    create index(:gallery_shares, [:gallery_id])

    # Favourites and album picks, attributed to whoever made them so the couple
    # can see which of them chose what.
    create table(:gallery_selections, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :gallery_id, references(:galleries, type: :uuid, on_delete: :delete_all), null: false
      add :media_id, references(:gallery_media, type: :uuid, on_delete: :delete_all), null: false
      add :share_id, references(:gallery_shares, type: :uuid, on_delete: :nilify_all)
      add :kind, :string, null: false, default: "favourite"
      add :note, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:gallery_selections, [:media_id, :share_id, :kind])
    create index(:gallery_selections, [:gallery_id, :kind])

    create constraint(:gallery_selections, :gallery_selections_kind_is_known,
             check: "kind IN ('favourite','album','print','reject')"
           )

    create table(:gallery_access_codes, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :gallery_id, references(:galleries, type: :uuid, on_delete: :delete_all), null: false
      add :email, :citext, null: false
      add :code_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:gallery_access_codes, [:gallery_id, :email])

    # Keep `galleries.media_count` and `galleries.bytes_total` exact without a
    # scan. The trigger is authoritative; application code never writes these.
    execute """
            CREATE OR REPLACE FUNCTION gallery_media_rollup()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'INSERT' THEN
                UPDATE galleries
                   SET media_count = media_count + 1,
                       bytes_total = bytes_total + NEW.byte_size
                 WHERE id = NEW.gallery_id;
              ELSIF TG_OP = 'DELETE' THEN
                UPDATE galleries
                   SET media_count = GREATEST(media_count - 1, 0),
                       bytes_total = GREATEST(bytes_total - OLD.byte_size, 0)
                 WHERE id = OLD.gallery_id;
              ELSIF TG_OP = 'UPDATE' AND NEW.byte_size <> OLD.byte_size THEN
                UPDATE galleries
                   SET bytes_total = GREATEST(bytes_total - OLD.byte_size + NEW.byte_size, 0)
                 WHERE id = NEW.gallery_id;
              END IF;
              RETURN NULL;
            END $$;
            """,
            "DROP FUNCTION IF EXISTS gallery_media_rollup()"

    execute """
            CREATE TRIGGER gallery_media_rollup_trigger
            AFTER INSERT OR UPDATE OR DELETE ON gallery_media
            FOR EACH ROW EXECUTE FUNCTION gallery_media_rollup()
            """,
            "DROP TRIGGER IF EXISTS gallery_media_rollup_trigger ON gallery_media"
  end
end
