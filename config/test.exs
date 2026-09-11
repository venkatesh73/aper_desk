import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :aper_desk, AperDesk.Repo,
  username: System.get_env("PGUSER") || System.get_env("USER"),
  password: System.get_env("PGPASSWORD") || "",
  hostname: System.get_env("PGHOST", "localhost"),
  database: "aper_desk_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :aper_desk, AperDeskWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "5A420Ei2Yqd+EQns/tJrStx9Tcoa0k+05JCoBM9quRp/43dCjEvP9MvkSZWd5YSx",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Jobs run inline in tests so assertions do not race a queue.
config :aper_desk, Oban, testing: :inline

config :aper_desk, AperDesk.Accounts.Guardian,
  issuer: "aper_desk",
  secret_key: "test-only-guardian-secret-not-used-in-any-real-environment"

config :aper_desk, AperDesk.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("YXBlcmRlc2stdGVzdC1vbmx5LXZhdWx0LWtleSEhISE=")}
  ]

# The Test adapter delivers into the test process's mailbox, which is what
# `Swoosh.TestAssertions` reads. Without it mail goes to the local previewer and
# tests cannot see it.
config :aper_desk, AperDesk.Mailer, adapter: Swoosh.Adapters.Test

# Uploads go to a throwaway directory, so a test that writes a file does not
# leave one in priv/static.
config :aper_desk, :storage,
  adapter: AperDesk.Storage.Local,
  root: "tmp/test_uploads",
  public_base_url: "/uploads"
