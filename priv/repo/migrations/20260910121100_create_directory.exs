defmodule AperDesk.Repo.Migrations.CreateDirectory do
  use Ecto.Migration

  @moduledoc """
  The public side: the "Find a photographer" directory, portfolios and reviews.

  The system being replaced promised a search page on its top plan but never
  shipped one, because listings had no home of their own — they would have had
  to be derived from private studio records. Here a listing is an explicit,
  separately-published record, so a studio can control exactly what the world
  sees without that leaking back into its private data.
  """

  def change do
    create table(:categories, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :key, :string, null: false
      add :name, :string, null: false
      add :position, :integer, null: false, default: 0
    end

    create unique_index(:categories, [:key])

    create table(:studio_categories, primary_key: false) do
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :category_id, references(:categories, type: :uuid, on_delete: :delete_all), null: false
      add :primary_category, :boolean, null: false, default: false
    end

    create unique_index(:studio_categories, [:studio_id, :category_id])

    create table(:directory_listings, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false

      add :headline, :string, null: false
      add :bio, :text
      add :city, :string, null: false
      add :country_code, :string, null: false
      add :latitude, :float
      add :longitude, :float
      add :travels_worldwide, :boolean, null: false, default: false
      add :travel_radius_km, :integer

      add :from_price_cents, :bigint
      add :from_price_currency, :string
      add :languages, {:array, :string}, null: false, default: []
      add :response_time_minutes, :integer

      add :cover_url, :string
      add :published_at, :utc_datetime_usec
      add :featured, :boolean, null: false, default: false
      add :rating_avg, :decimal
      add :rating_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:directory_listings, [:studio_id])
    create index(:directory_listings, [:city, :country_code], where: "published_at IS NOT NULL")
    create index(:directory_listings, [:featured, :rating_avg])

    execute "CREATE INDEX directory_listings_headline_trgm ON directory_listings USING gin (headline gin_trgm_ops)",
            "DROP INDEX directory_listings_headline_trgm"

    create table(:portfolio_items, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :title, :string
      add :caption, :string
      add :storage_key, :string, null: false
      add :url, :string
      add :shoot_type, :string
      add :width, :integer
      add :height, :integer
      add :position, :integer, null: false, default: 0
      add :published, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:portfolio_items, [:studio_id, :position])

    # Reviews are tied to a job, so a rating cannot be left by someone who never
    # booked. That is the whole difference between a directory people trust and
    # one they do not.
    create table(:reviews, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :studio_id, references(:studios, type: :uuid, on_delete: :delete_all), null: false
      add :job_id, references(:jobs, type: :uuid, on_delete: :nilify_all)
      add :contact_id, references(:contacts, type: :uuid, on_delete: :nilify_all)
      add :author_name, :string, null: false
      add :rating, :integer, null: false
      add :body, :text
      add :shoot_type, :string
      add :published_at, :utc_datetime_usec
      add :studio_reply, :text
      add :replied_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:reviews, [:job_id], where: "job_id IS NOT NULL")
    create index(:reviews, [:studio_id, :published_at])
    create constraint(:reviews, :reviews_rating_in_range, check: "rating BETWEEN 1 AND 5")
  end
end
