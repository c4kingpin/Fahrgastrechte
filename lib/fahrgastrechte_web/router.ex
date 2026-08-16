defmodule FahrgastrechteWeb.Router do
  use FahrgastrechteWeb, :router

  import FahrgastrechteWeb.UserAuth

  # The application serves exactly one stylesheet and one script from its own
  # origin and embeds nothing external, so the policy can stay strict.
  #
  # `style-src` is the one exception: the three progress bars in
  # `ClaimLive.Show`, `ClaimLive.Components` and `ReferenceDataLive` set their
  # width through an inline style attribute. Replacing them with a native
  # `<progress>` element styled from app.css would allow dropping
  # 'unsafe-inline' here. Script execution stays strictly same-origin.
  @content_security_policy [
                             "default-src 'self'",
                             "script-src 'self'",
                             "style-src 'self' 'unsafe-inline'",
                             "img-src 'self' data:",
                             "font-src 'self'",
                             "connect-src 'self' ws: wss:",
                             "form-action 'self'",
                             "frame-ancestors 'none'",
                             "base-uri 'none'",
                             "object-src 'none'"
                           ]
                           |> Enum.join("; ")

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FahrgastrechteWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
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
