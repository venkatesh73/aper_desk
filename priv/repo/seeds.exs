# Seeds the data the product cannot function without: the three sellable plans
# and the directory categories.
#
# Idempotent by design — `mix ecto.setup` runs it, and so does a developer
# who just wants to top up a database that already has rows. Every insert is an
# upsert on the natural key, so running it twice changes nothing.
#
#     mix run priv/repo/seeds.exs

alias AperDesk.Billing.Plan
alias AperDesk.Directory.Category
alias AperDesk.Repo

gb = 1_073_741_824

plans = [
  %{
    key: "solo",
    name: "Solo",
    tagline: "For the solo photographer moving off spreadsheets.",
    monthly_price_cents: 1500,
    yearly_price_cents: 16_200,
    position: 1,
    features: ~w(online_booking esignature client_portal csv_export),
    limits: %{
      "seats" => 1,
      "active_leads" => 50,
      "active_galleries" => 10,
      "storage_bytes" => 10 * gb,
      "gallery_window_days" => 60,
      "packages" => 2,
      "forms" => 1,
      "workflows" => 3,
      "contract_templates" => 5,
      "emails_per_lead" => 5
    }
  },
  %{
    key: "studio",
    name: "Studio",
    tagline: "For the working photographer scaling up.",
    monthly_price_cents: 2400,
    yearly_price_cents: 25_920,
    extra_seat_price_cents: 350,
    position: 2,
    features: ~w(online_booking esignature client_portal csv_export ai_replies clash_detection
         nurture_sequences remove_badge priority_support),
    limits: %{
      "seats" => 3,
      "active_galleries" => 50,
      "storage_bytes" => 100 * gb,
      "gallery_window_days" => 180,
      "packages" => 10,
      "emails_per_lead" => 10
    }
  },
  %{
    key: "agency",
    name: "Agency",
    tagline: "For multi-shooter studios and agencies.",
    monthly_price_cents: 3500,
    yearly_price_cents: 37_800,
    position: 3,
    features: ~w(online_booking esignature client_portal csv_export ai_replies clash_detection
         nurture_sequences remove_badge crew_payouts bulk_gallery_ops featured_listing
         early_access dedicated_support all_roles),
    # Every limit omitted is unlimited — see `AperDesk.Billing.Plan.limit/2`.
    # Storage and the delivery window are the only real caps on this tier.
    limits: %{
      "storage_bytes" => 500 * gb,
      "gallery_window_days" => 365
    }
  }
]

for attrs <- plans do
  case Repo.get_by(Plan, key: attrs.key, version: 1) do
    nil -> %Plan{}
    existing -> existing
  end
  |> Plan.changeset(Map.put(attrs, :currency, "USD"))
  |> Repo.insert_or_update!()
end

categories = [
  {"wedding", "Wedding"},
  {"portrait", "Portrait"},
  {"newborn", "Newborn & family"},
  {"event", "Event"},
  {"commercial", "Commercial"},
  {"product", "Product"},
  {"real_estate", "Real estate"}
]

for {{key, name}, position} <- Enum.with_index(categories, 1) do
  case Repo.get_by(Category, key: key) do
    nil -> %Category{}
    existing -> existing
  end
  |> Category.changeset(%{key: key, name: name, position: position})
  |> Repo.insert_or_update!()
end

# Indicative FX rates so the pricing page can quote in EUR and INR.
#
# Placeholders, not a feed. A rate is stored per day and never overwritten,
# because an issued invoice must always convert at the rate that applied when it
# was issued — see `AperDesk.Finance.FxRate`. In production a daily job writes
# these; here we seed today so the currency switcher has something true to say.
# The landing page only offers a currency it has a rate for, so removing these
# hides the switcher rather than showing wrong prices.
alias AperDesk.Finance.FxRate

today = Date.utc_today()

for {quote_currency, rate} <- [{"EUR", "0.92"}, {"INR", "83.50"}] do
  case Repo.get_by(FxRate, base_currency: "USD", quote_currency: quote_currency, as_of: today) do
    nil -> %FxRate{}
    existing -> existing
  end
  |> FxRate.changeset(%{
    base_currency: "USD",
    quote_currency: quote_currency,
    rate: Decimal.new(rate),
    as_of: today,
    source: "manual"
  })
  |> Repo.insert_or_update!()
end

IO.puts("Seeded #{length(plans)} plans, #{length(categories)} categories and 2 FX rates.")
