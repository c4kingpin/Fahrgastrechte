defmodule FahrgastrechteWeb.Router do
  use FahrgastrechteWeb, :router

  import FahrgastrechteWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FahrgastrechteWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope
  end

  pipeline :authenticated do
    plug :require_authenticated_user
    plug FahrgastrechteWeb.Plugs.PutPrivateCacheHeaders
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FahrgastrechteWeb do
    pipe_through :api

    get "/healthz", HealthController, :health
    get "/readyz", HealthController, :readiness
  end

  scope "/", FahrgastrechteWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/anmelden", AuthController, :login
    get "/auth/callback", AuthController, :callback
    get "/auth/abgemeldet", AuthController, :logged_out
    delete "/abmelden", AuthController, :logout
  end

  scope "/", FahrgastrechteWeb do
    pipe_through [:browser, :authenticated]

    get "/dokumente/:id/download", DocumentController, :download

    live_session :require_authenticated_user,
      on_mount: [{FahrgastrechteWeb.UserAuth, :require_authenticated}] do
      live "/profil", ProfileLive, :edit
      live "/datenquellen", ReferenceDataLive, :index
      live "/antraege", ClaimLive.Index, :index
      live "/antraege/:id", ClaimLive.Show, :show
      live "/antraege/:id/:step", ClaimLive.Show, :show
    end
  end

  # Enable LiveDashboard in development.
  if Application.compile_env(:fahrgastrechte, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FahrgastrechteWeb.Telemetry
    end
  end
end
