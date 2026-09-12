defmodule AperDesk.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AperDeskWeb.Telemetry,
      # The vault must start before the Repo: Cloak-encrypted columns fail to
      # dump if their vault is not running, and a failed dump is silent enough
      # to look like a validation error rather than a missing process.
      AperDesk.Vault,
      AperDesk.Repo,
      {DNSCluster, query: Application.get_env(:aper_desk, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AperDesk.PubSub},
      # Background work. After the Repo, because every queue and every plugin
      # needs it; before the Endpoint, so a request cannot enqueue a job into a
      # supervisor that has not started yet.
      {Oban, Application.fetch_env!(:aper_desk, Oban)},
      # Start to serve requests, typically the last entry
      AperDeskWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AperDesk.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AperDeskWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
