defmodule Fahrgastrechte.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:fahrgastrechte, :env) == :prod do
      Fahrgastrechte.Documents.CommandRunner.ensure_timeout_tool!()
    end

    children = [
      FahrgastrechteWeb.Telemetry,
      Fahrgastrechte.Repo,
      {DNSCluster, query: Application.get_env(:fahrgastrechte, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Fahrgastrechte.PubSub},
      {Task.Supervisor, name: Fahrgastrechte.ExternalCommandSupervisor},
      {Fahrgastrechte.Documents.PDFJobLimiter, max_concurrency: 2},
      {Fahrgastrechte.Rail.RateLimiter, rate: 45, window_ms: 60_000, max_concurrency: 2},
      {Fahrgastrechte.Documents.CleanupWorker,
       Application.get_env(:fahrgastrechte, Fahrgastrechte.Documents.CleanupWorker, [])},
      # Start a worker by calling: Fahrgastrechte.Worker.start_link(arg)
      # {Fahrgastrechte.Worker, arg},
      # Start to serve requests, typically the last entry
      FahrgastrechteWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fahrgastrechte.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FahrgastrechteWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
