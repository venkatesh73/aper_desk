defmodule AperDesk.MixProject do
  use Mix.Project

  def project do
    [
      app: :aper_desk,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {AperDesk.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        qa: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # --- GraphQL API (mobile clients) ---
      {:absinthe, "~> 1.7"},
      {:absinthe_plug, "~> 1.5"},
      {:absinthe_phoenix, "~> 2.0"},
      {:dataloader, "~> 2.0"},
      {:corsica, "~> 2.1"},

      # --- Auth ---
      {:guardian, "~> 2.3"},
      {:argon2_elixir, "~> 4.0"},

      # --- Background jobs ---
      {:oban, "~> 2.19"},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},

      # --- Mail ---
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"},
      {:finch, "~> 0.19"},
      {:req, "~> 0.5"},

      # --- Object storage (galleries) ---
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      {:hackney, "~> 1.20"},

      # --- Billing ---
      {:stripity_stripe, "~> 3.2"},

      # --- Data helpers ---
      {:cloak_ecto, "~> 1.3"},
      {:tz, "~> 0.28"},
      {:csv, "~> 3.2"},
      {:html_sanitize_ex, "~> 1.4"},
      {:hammer, "~> 6.2"},

      # --- Dev / test tooling ---
      {:ex_machina, "~> 2.8", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      # One command before pushing. Order matters: formatting and compile
      # warnings are cheap and fail fast, the suite is slower, and coverage is
      # last because it re-runs everything.
      qa: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "coveralls"
      ],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind aper_desk", "esbuild aper_desk"],
      "assets.deploy": [
        "tailwind aper_desk --minify",
        "esbuild aper_desk --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
