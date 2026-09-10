defmodule AperDesk.Repo.Migrations.CreateCatalog do
  use Ecto.Migration

  @moduledoc "Packages: what the studio sells, with sample media and inclusions."

  def change do
    create table(:packages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :citext, null: false
      add :summary, :string
      add :description, :text
      add :shoot_type, :string, null: false, default: "other"

      add :price_cents, :bigint, null: false, default: 0
      add :price_currency, :string, null: false, default: "USD"
      add :deposit_percent, :integer, null: false, default: 25

      add :duration_minutes, :integer
      add :crew_size, :integer, null: false, default: 1
      add :delivery_days, :integer, null: false, default: 30
      add :edited_image_count, :integer

      add :public, :boolean, null: false, default: true
      add :position, :integer, null: false, default: 0
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:packages, [:studio_id, :slug])
    create index(:packages, [:studio_id, :public])

    create constraint(:packages, :packages_currency_is_iso,
             check: "assert_currency(price_currency)"
           )

    create constraint(:packages, :packages_deposit_percent_in_range,
             check: "deposit_percent BETWEEN 0 AND 100"
           )

    create table(:package_items, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :package_id, references(:packages, type: :uuid, on_delete: :delete_all), null: false
      add :label, :string, null: false
      add :detail, :string
      add :included, :boolean, null: false, default: true
      add :position, :integer, null: false, default: 0
    end

    create index(:package_items, [:package_id])

    create table(:package_media, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :package_id, references(:packages, type: :uuid, on_delete: :delete_all), null: false
      add :storage_key, :string, null: false
      add :url, :string
      add :alt, :string
      add :position, :integer, null: false, default: 0
    end

    create index(:package_media, [:package_id])
  end
end
