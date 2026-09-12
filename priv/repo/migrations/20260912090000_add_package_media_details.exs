defmodule AperDesk.Repo.Migrations.AddPackageMediaDetails do
  use Ecto.Migration

  @moduledoc """
  Package media was a bare `storage_key` with no tenancy and no shape.

  It needs `studio_id` for the same reason every other table has one — a row
  that can only be reached through its parent cannot be scoped, swept or
  counted without a join — and it needs to know what it is holding, because a
  5 MB limit on stills and a 10 MB limit on video cannot be enforced against a
  row that does not record which it is.
  """

  def up do
    alter table(:package_media) do
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all)
      add :kind, :string
      add :content_type, :string
      add :filename, :string
      add :byte_size, :bigint
    end

    # Backfill from the parent before the column is made required. Existing
    # rows are development leftovers, but a migration that assumes an empty
    # table is one that fails the first time it meets a real one.
    execute """
    UPDATE package_media m
       SET studio_id = p.studio_id
      FROM packages p
     WHERE p.id = m.package_id
    """

    execute "UPDATE package_media SET kind = 'image' WHERE kind IS NULL"
    execute "UPDATE package_media SET byte_size = 0 WHERE byte_size IS NULL"

    alter table(:package_media) do
      modify :studio_id, :uuid, null: false
      modify :kind, :string, null: false
      modify :byte_size, :bigint, null: false, default: 0
    end

    create constraint(:package_media, :package_media_kind, check: "kind IN ('image','video')")

    create index(:package_media, [:studio_id])
  end

  def down do
    drop constraint(:package_media, :package_media_kind)
    drop index(:package_media, [:studio_id])

    alter table(:package_media) do
      remove :studio_id
      remove :kind
      remove :content_type
      remove :filename
      remove :byte_size
    end
  end
end
