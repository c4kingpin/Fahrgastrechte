# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :fahrgastrechte,
  ecto_repos: [Fahrgastrechte.Repo],
  generators: [timestamp_type: :utc_datetime],
  identity_provider: Fahrgastrechte.Accounts.Authentik,
  secure_session_cookie: true

config :fahrgastrechte, Fahrgastrechte.Accounts.Authentik,
  issuer: nil,
  client_id: nil,
  client_secret: nil,
  allowed_algorithms: ["RS256"]

config :fahrgastrechte, Fahrgastrechte.Documents,
  max_file_size_bytes: 10 * 1024 * 1024,
  max_page_count: 20,
  command_timeout_ms: 10_000,
  pdfinfo_executable: "pdfinfo"

config :fahrgastrechte, Fahrgastrechte.Documents.LocalStorage,
  path: Path.expand("../tmp/documents", __DIR__)

config :fahrgastrechte, Fahrgastrechte.Tickets,
  extractor: Fahrgastrechte.Tickets.PopplerExtractor,
  pdftotext_executable: "pdftotext",
  command_timeout_ms: 10_000,
  max_text_bytes: 1024 * 1024

config :fahrgastrechte, Fahrgastrechte.Rail,
  provider: Fahrgastrechte.Rail.Providers.Timetables,
  max_snapshot_bytes: 5 * 1024 * 1024

config :fahrgastrechte, Fahrgastrechte.Rail.Providers.Timetables,
  base_url: "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1",
  client_id: nil,
  api_key: nil,
  max_response_bytes: 5 * 1024 * 1024

config :fahrgastrechte, Fahrgastrechte.Rail.Providers.BahnVorhersageArchive,
  data_path: nil,
  dataset_version: nil,
  station_names: %{}

config :fahrgastrechte, Fahrgastrechte.Exports,
  backend: Fahrgastrechte.Exports.SystemPDFBackend,
  template_path: Path.expand("../priv/form_templates/fahrgastrechte-2025-me-08-25.pdf", __DIR__),
  template_manifest_path:
    Path.expand("../priv/form_templates/fahrgastrechte-2025-me-08-25.json", __DIR__),
  template_version: "Formular 2025 (ME/08/25)",
  template_source:
    "https://cms.static-bahn.de/wmedia/redaktion/aushaenge/fahrgastrechte/Fahrgastrechte-Formular_deutsch-feb25-2.pdf",
  template_sha256:
    Base.decode16!("4A30F9C7F00593BF5BDA1B6EAA2D1B6E293357FAA48631A1D7E2ADE3B77A39A9"),
  max_file_size_bytes: 15 * 1024 * 1024,
  max_page_count: 20,
  command_timeout_ms: 30_000,
  qpdf_executable: "qpdf",
  pdfinfo_executable: "pdfinfo",
  pdftk_executable: "pdftk",
  pdftocairo_executable: "pdftocairo",
  font_path: "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

# Configure the endpoint
config :fahrgastrechte, FahrgastrechteWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FahrgastrechteWeb.ErrorHTML, json: FahrgastrechteWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Fahrgastrechte.PubSub,
  live_view: [signing_salt: "lF1fi6Wx"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  fahrgastrechte: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  fahrgastrechte: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :filter_parameters, [
  "password",
  "secret",
  "token",
  "authorization",
  "code",
  "iban",
  "bic",
  "account_holder",
  "DB_API_KEY",
  "AUTHENTIK_CLIENT_SECRET",
  "FIELD_ENCRYPTION_KEY",
  "SECRET_KEY_BASE"
]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
