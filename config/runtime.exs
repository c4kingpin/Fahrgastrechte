import Config

runtime_environment = config_env()

field_encryption_key =
  case {runtime_environment, System.get_env("FIELD_ENCRYPTION_KEY")} do
    {:prod, nil} ->
      raise "FIELD_ENCRYPTION_KEY is missing"

    {_environment, nil} ->
      :crypto.hash(:sha256, "fahrgastrechte-development-only-field-key")

    {_environment, encoded_key} ->
      case Base.decode64(encoded_key) do
        {:ok, key} when byte_size(key) == 32 ->
          key

        _other ->
          raise "FIELD_ENCRYPTION_KEY must be a Base64-encoded 32-byte key"
      end
  end

field_encryption_key_version =
  System.get_env("FIELD_ENCRYPTION_KEY_VERSION", "1")
  |> Integer.parse()
  |> case do
    {version, ""} when version > 0 -> version
    _other -> raise "FIELD_ENCRYPTION_KEY_VERSION must be a positive integer"
  end

config :fahrgastrechte, Fahrgastrechte.Accounts.BankDataCipher,
  active_key_version: field_encryption_key_version,
  keys: %{field_encryption_key_version => field_encryption_key}

config :fahrgastrechte, Fahrgastrechte.Accounts.Authentik,
  issuer: System.get_env("AUTHENTIK_ISSUER"),
  client_id: System.get_env("AUTHENTIK_CLIENT_ID"),
  client_secret: System.get_env("AUTHENTIK_CLIENT_SECRET")

config :fahrgastrechte, Fahrgastrechte.Rail.Providers.Timetables,
  client_id: System.get_env("DB_CLIENT_ID"),
  api_key: System.get_env("DB_API_KEY")

config :fahrgastrechte, Fahrgastrechte.Rail.Providers.BahnVorhersageArchive,
  data_path: System.get_env("BAHNVORHERSAGE_DATA_PATH"),
  dataset_version: System.get_env("BAHNVORHERSAGE_DATASET_VERSION")

if form_template_path = System.get_env("FORM_TEMPLATE_PATH") do
  config :fahrgastrechte, Fahrgastrechte.Exports, template_path: form_template_path
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/fahrgastrechte start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :fahrgastrechte, FahrgastrechteWeb.Endpoint, server: true
end

if config_env() != :prod do
  config :fahrgastrechte, FahrgastrechteWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :fahrgastrechte, FahrgastrechteWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/fahrgastrechte_web/router\.ex$"E,
        ~r"lib/fahrgastrechte_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  positive_integer = fn name, default ->
    name
    |> System.get_env(default)
    |> Integer.parse()
    |> case do
      {value, ""} when value > 0 -> value
      _other -> raise "#{name} must be a positive integer"
    end
  end

  document_storage_path =
    System.get_env("DOCUMENT_STORAGE_PATH") ||
      raise "DOCUMENT_STORAGE_PATH is missing"

  if Path.type(document_storage_path) != :absolute do
    raise "DOCUMENT_STORAGE_PATH must be an absolute path"
  end

  config :fahrgastrechte, Fahrgastrechte.Documents.LocalStorage, path: document_storage_path

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :fahrgastrechte, Fahrgastrechte.Repo,
    url: database_url,
    pool_size: positive_integer.("POOL_SIZE", "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing"

  host =
    System.get_env("PHX_HOST") ||
      raise "PHX_HOST is missing"

  if not Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/, host) do
    raise "PHX_HOST must be a hostname without scheme, port or path"
  end

  bind_address = System.get_env("PHX_BIND_ADDRESS", "0.0.0.0")

  bind_ip =
    case :inet.parse_address(String.to_charlist(bind_address)) do
      {:ok, address} -> address
      {:error, _reason} -> raise "PHX_BIND_ADDRESS must be an IPv4 or IPv6 address"
    end

  config :fahrgastrechte, :canonical_host, host
  config :fahrgastrechte, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :fahrgastrechte, FahrgastrechteWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: bind_ip, port: positive_integer.("PORT", "4000")],
    check_origin: ["//#{host}"],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :fahrgastrechte, FahrgastrechteWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :fahrgastrechte, FahrgastrechteWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :fahrgastrechte, Fahrgastrechte.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
