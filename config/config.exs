# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :aper_desk,
  ecto_repos: [AperDesk.Repo],
  # UUIDv7 primary keys everywhere: sortable like a serial, but unguessable and
  # safe to mint client-side, which the mobile app needs for offline creates.
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

# Configure the endpoint
config :aper_desk, AperDeskWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AperDeskWeb.ErrorHTML, json: AperDeskWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AperDesk.PubSub,
  live_view: [signing_salt: "FCgIC7/R"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  aper_desk: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  aper_desk: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# --- Background jobs -------------------------------------------------------
# Oban is the spine of every automation. Queues are separated by failure mode so
# a stuck gallery upload can never starve outbound email.
config :aper_desk, Oban,
  repo: AperDesk.Repo,
  engine: Oban.Engines.Basic,
  queues: [
    default: 10,
    mailers: 20,
    automation: 10,
    galleries: 5,
    billing: 5,
    inbound: 10
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", AperDesk.Automation.Workers.OutboxDrainWorker},
       {"0 * * * *", AperDesk.Comms.Workers.InboxSyncWorker},
       {"0 2 * * *", AperDesk.Galleries.Workers.ArchiveExpiredWorker},
       {"0 3 * * *", AperDesk.Galleries.Workers.ExpiryReminderWorker},
       {"0 6 * * *", AperDesk.Finance.Workers.InvoiceReminderWorker},
       {"30 6 * * *", AperDesk.Billing.Workers.UsageRollupWorker}
     ]}
  ]

# --- Authentication --------------------------------------------------------
config :aper_desk, AperDesk.Accounts.Guardian,
  issuer: "aper_desk",
  ttl: {2, :weeks},
  token_ttl: %{"access" => {30, :minutes}, "refresh" => {60, :days}}

# --- GraphQL ---------------------------------------------------------------
# The mobile app is a first-class client, so GraphQL is a peer of the LiveView
# UI rather than an afterthought bolted onto controllers.
config :aper_desk, AperDeskWeb.Graphql,
  max_complexity: 300,
  max_depth: 12,
  introspection_in_prod: false

# --- Mail ------------------------------------------------------------------
config :aper_desk, AperDesk.Mailer, adapter: Swoosh.Adapters.Local

# The address account email is sent from. Overridden in runtime.exs.
config :aper_desk, :mail, from: "no-reply@aperdesk.com"

# Google sign-in. Credentials come from the environment; with none set the
# feature reports itself unconfigured and the button is not rendered, rather
# than offering a flow that dead-ends at Google's error page.
config :aper_desk, AperDesk.Accounts.Google,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

config :swoosh, :api_client, false

# --- Object storage --------------------------------------------------------
config :ex_aws,
  json_codec: Jason,
  region: "auto"

# --- Money -----------------------------------------------------------------
# Amounts are stored as integer minor units plus a currency code. Never floats.
config :aper_desk, :money,
  base_currency: "USD",
  supported: ["USD", "EUR", "INR"]

# --- Rate limiting ---------------------------------------------------------
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 2, cleanup_interval_ms: 60_000 * 10]}

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
