defmodule AperDesk.Accounts.Studio do
  @moduledoc "The tenant. Everything else in the system hangs off one of these."
  use AperDesk.Schema

  alias AperDesk.Accounts.Membership

  @onboarding_states ~w(new inbox_connected packages_added first_lead ready)
  @date_formats ~w(dmy mdy iso long)
  @time_formats ~w(12h 24h)
  @week_starts ~w(monday sunday)

  schema "studios" do
    field :name, :string
    field :slug, :string
    field :tagline, :string
    field :about, :string
    field :website, :string
    field :support_email, :string
    field :phone, :string

    field :logo_url, :string
    field :brand_color, :string, default: "#B8722E"

    field :base_currency, :string, default: "USD"
    field :time_zone, :string, default: "Etc/UTC"
    field :country_code, :string
    field :city, :string

    field :reply_sla_minutes, :integer, default: 240

    field :listed_in_directory, :boolean, default: false
    field :featured_until, :utc_datetime_usec

    field :date_format, :string, default: "dmy"
    field :time_format, :string, default: "24h"
    field :week_starts_on, :string, default: "monday"
    field :setup_completed_at, :utc_datetime_usec

    field :onboarding_state, :string, default: "new"
    field :archived_at, :utc_datetime_usec

    has_many :memberships, Membership

    timestamps()
  end

  def changeset(studio, attrs) do
    studio
    |> cast(attrs, [
      :name,
      :slug,
      :tagline,
      :about,
      :website,
      :support_email,
      :phone,
      :logo_url,
      :brand_color,
      :base_currency,
      :time_zone,
      :country_code,
      :city,
      :reply_sla_minutes,
      :listed_in_directory,
      :onboarding_state,
      :date_format,
      :time_format,
      :week_starts_on
    ])
    |> validate_required([:name, :base_currency, :time_zone])
    |> maybe_generate_slug()
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "may only contain lowercase letters, numbers and hyphens"
    )
    |> validate_length(:slug, min: 3, max: 60)
    |> validate_inclusion(:base_currency, AperDesk.Money.supported_currencies())
    |> validate_inclusion(:onboarding_state, @onboarding_states)
    |> validate_inclusion(:date_format, @date_formats)
    |> validate_inclusion(:time_format, @time_formats)
    |> validate_inclusion(:week_starts_on, @week_starts)
    |> validate_format(:brand_color, ~r/^#[0-9A-Fa-f]{6}$/, message: "must be a hex colour")
    |> validate_number(:reply_sla_minutes, greater_than: 0, less_than_or_equal_to: 10_080)
    |> validate_time_zone()
    |> unique_constraint(:slug)
  end

  def date_formats, do: @date_formats
  def time_formats, do: @time_formats
  def week_starts, do: @week_starts

  @doc """
  The first-run setup form.

  Requires the answers the product cannot sensibly guess. Currency and time zone
  are the two that silently corrupt everything downstream if wrong — a quote in
  the wrong currency and a shoot on the wrong day — so they are required rather
  than defaulted past.
  """
  def setup_changeset(studio, attrs) do
    studio
    |> cast(attrs, [
      :base_currency,
      :time_zone,
      :country_code,
      :city,
      :date_format,
      :time_format,
      :week_starts_on,
      :reply_sla_minutes
    ])
    |> validate_required([:base_currency, :time_zone, :city, :country_code])
    |> validate_inclusion(:base_currency, AperDesk.Money.supported_currencies())
    |> validate_inclusion(:date_format, @date_formats)
    |> validate_inclusion(:time_format, @time_formats)
    |> validate_inclusion(:week_starts_on, @week_starts)
    |> validate_format(:country_code, ~r/^[A-Z]{2}$/,
      message: "must be a two-letter country code"
    )
    |> validate_number(:reply_sla_minutes, greater_than: 0, less_than_or_equal_to: 10_080)
    |> validate_time_zone()
    |> put_change(:setup_completed_at, DateTime.utc_now())
  end

  @doc "Whether the studio has been through first-run setup."
  def configured?(%__MODULE__{setup_completed_at: %DateTime{}}), do: true
  def configured?(%__MODULE__{}), do: false

  defp maybe_generate_slug(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :name)} do
      {nil, name} when is_binary(name) -> put_change(changeset, :slug, slugify(name))
      _ -> changeset
    end
  end

  defp slugify(name) do
    name
    # Decompose accents so "Aperture & Cô" becomes "aperture-co" rather than
    # losing the character entirely.
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # A bad time zone would silently shift every shoot on the calendar, so it is
  # checked at the boundary rather than at render time.
  defp validate_time_zone(changeset) do
    validate_change(changeset, :time_zone, fn :time_zone, tz ->
      case DateTime.now(tz) do
        {:ok, _} -> []
        _ -> [time_zone: "is not a known time zone"]
      end
    end)
  end
end
