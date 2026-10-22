import Config

config :fahrgastrechte, secure_session_cookie: false
config :fahrgastrechte, development_login: true
config :fahrgastrechte, development_identity: nil

config :fahrgastrechte, Fahrgastrechte.Documents, max_file_size_bytes: 1024 * 1024

# Sweeps run outside the test sandbox, so tests drive the cleanup directly.
config :fahrgastrechte, Fahrgastrechte.Documents.CleanupWorker, enabled: false

# Same reasoning: the catalog sync runs outside the test sandbox, so tests
# drive it directly via StationCatalogSyncWorker.run_now/2.
config :fahrgastrechte, Fahrgastrechte.Rail.StationCatalogSyncWorker, enabled: false

config :fahrgastrechte, Fahrgastrechte.Documents.LocalStorage,
  path: Path.join(System.tmp_dir!(), "fahrgastrechte-test-documents")

config :fahrgastrechte, Fahrgastrechte.Exports,
  backend: Fahrgastrechte.TestPDFBackend,
  template_path: Path.expand("../test/fixtures/c00/synthetic-ticket-flexpreis.pdf", __DIR__),
  template_manifest_path: Path.expand("../test/fixtures/c00/form-template.json", __DIR__),
  template_version: "synthetic-test-template-v1",
  template_source: "fixture://synthetic-ticket-flexpreis.pdf",
  template_sha256:
    Base.decode16!("9F4AB733E67F4790B307C930EB655352782C07AC0357336E34A19DD571AE4473")

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
database_name = System.get_env("DATABASE_NAME", "fahrgastrechte_test")

config :fahrgastrechte, Fahrgastrechte.Repo,
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  database: "#{database_name}#{System.get_env("MIX_TEST_PARTITION")}",
  template: System.get_env("DATABASE_TEMPLATE", "template0"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# The server runs during tests so the Playwright feature tests in
# test/features can drive the app in a real browser.
config :fahrgastrechte, FahrgastrechteWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "2Qt2yUoIkwD8rYnhGiMKBVk3U7Gbx2SeKi3ECgPQtdypjDOCUOpIkl3C9MUGdByF",
  server: true

# Lets browser requests and LiveView processes join the test's SQL sandbox.
# Compiled into the endpoint and router only when set, so never in a release.
config :fahrgastrechte, sql_sandbox: true

config :phoenix_test,
  otp_app: :fahrgastrechte,
  endpoint: FahrgastrechteWeb.Endpoint,
  playwright: [
    browser_pools: [[id: :chromium, browser: :chromium, size: 2]],
    browser_pool: :chromium,
    browser_context_opts: [locale: "de-DE", timezone_id: "Europe/Berlin"],
    timeout: :timer.seconds(5),
    ecto_sandbox_stop_owner_delay: 100,
    screenshot: System.get_env("PW_SCREENSHOT", "false") in ~w(t true),
    trace: System.get_env("PW_TRACE", "false") in ~w(t true)
  ]

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
