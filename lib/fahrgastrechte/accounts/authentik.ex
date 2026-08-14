defmodule Fahrgastrechte.Accounts.Authentik do
  @moduledoc """
  Authentik OpenID Connect adapter.

  It implements the Authorization Code flow with PKCE and validates the ID
  token against the issuer's discovery document and JWKS before returning a
  trusted local identity.
  """

  @behaviour Fahrgastrechte.Accounts.IdentityProvider

  alias Fahrgastrechte.Accounts.AuthenticatedSession
  alias Fahrgastrechte.Accounts.Identity

  @default_allowed_algorithms ["RS256"]
  @supported_algorithms ~w(RS256 RS384 RS512 PS256 PS384 PS512)
  @default_flow_ttl_seconds 600
  @default_session_ttl_seconds 8 * 60 * 60
  @default_max_token_age_seconds 600
  @default_clock_skew_seconds 60
  @max_json_bytes 1024 * 1024
  @max_id_token_bytes 32 * 1024

  @impl true
  def authorization_request(callback_uri) when is_binary(callback_uri) do
    with {:ok, config} <- configuration(),
         :ok <- validate_application_uri(callback_uri),
         {:ok, discovery} <- fetch_discovery(config) do
      state = random_urlsafe(32)
      nonce = random_urlsafe(32)
      code_verifier = random_urlsafe(64)

      session_state = %{
        "state" => state,
        "nonce" => nonce,
        "code_verifier" => code_verifier,
        "redirect_uri" => callback_uri,
        "created_at" => now()
      }

      params = %{
        "client_id" => config.client_id,
        "code_challenge" => pkce_challenge(code_verifier),
        "code_challenge_method" => "S256",
        "nonce" => nonce,
        "redirect_uri" => callback_uri,
        "response_type" => "code",
        "scope" => "openid profile email",
        "state" => state
      }

      {:ok,
       %{
         uri: append_query(discovery["authorization_endpoint"], params),
         session_state: session_state
       }}
    end
  end

  def authorization_request(_callback_uri), do: {:error, :invalid_callback_uri}

  @impl true
  def validate_callback(callback_params, session_state)
      when is_map(callback_params) and is_map(session_state) do
    with {:ok, config} <- configuration(),
         :ok <- validate_flow(session_state, config),
         :ok <- validate_state(callback_params, session_state),
         :ok <- validate_provider_response(callback_params),
         {:ok, code} <- required_binary(callback_params, "code", :invalid_callback),
         {:ok, discovery} <- fetch_discovery(config),
         {:ok, token_response} <- exchange_code(code, session_state, discovery, config),
         {:ok, id_token} <- required_binary(token_response, "id_token", :missing_id_token),
         {:ok, claims} <-
           validate_id_token(id_token, token_response, session_state, discovery, config),
         {:ok, identity} <- identity_from_claims(claims) do
      {:ok,
       %AuthenticatedSession{
         identity: identity,
         expires_at: now() + config.session_ttl_seconds,
         id_token: id_token
       }}
    end
  end

  def validate_callback(_callback_params, _session_state), do: {:error, :invalid_callback}

  @impl true
  def logout_uri(id_token_hint, return_to) when is_binary(return_to) do
    with {:ok, config} <- configuration(),
         :ok <- validate_application_uri(return_to),
         {:ok, discovery} <- fetch_discovery(config),
         {:ok, endpoint} <-
           required_binary(discovery, "end_session_endpoint", :logout_not_supported) do
      params =
        %{
          "client_id" => config.client_id,
          "post_logout_redirect_uri" => return_to
        }
        |> maybe_put_id_token_hint(id_token_hint)

      {:ok, append_query(endpoint, params)}
    end
  end

  def logout_uri(_id_token_hint, _return_to), do: {:error, :invalid_logout_uri}

  defp configuration do
    config = Application.get_env(:fahrgastrechte, __MODULE__, [])
    issuer = Keyword.get(config, :issuer)
    client_id = Keyword.get(config, :client_id)
    client_secret = Keyword.get(config, :client_secret)
    allowed_algorithms = Keyword.get(config, :allowed_algorithms, @default_allowed_algorithms)

    with :ok <- validate_issuer(issuer),
         :ok <- validate_non_empty(client_id, :missing_client_id),
         :ok <- validate_non_empty(client_secret, :missing_client_secret),
         :ok <- validate_algorithms(allowed_algorithms) do
      {:ok,
       %{
         issuer: issuer,
         issuer_uri: URI.parse(issuer),
         client_id: client_id,
         client_secret: client_secret,
         allowed_algorithms: allowed_algorithms,
         flow_ttl_seconds: positive_config(config, :flow_ttl_seconds, @default_flow_ttl_seconds),
         session_ttl_seconds:
           positive_config(config, :session_ttl_seconds, @default_session_ttl_seconds),
         max_token_age_seconds:
           positive_config(config, :max_token_age_seconds, @default_max_token_age_seconds),
         clock_skew_seconds:
           positive_config(config, :clock_skew_seconds, @default_clock_skew_seconds),
         http_options: Keyword.get(config, :http_options, [])
       }}
    end
  end

  defp positive_config(config, key, default) do
    case Keyword.get(config, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp validate_issuer(issuer) when is_binary(issuer) and issuer != "" do
    uri = URI.parse(issuer)

    if uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) do
      :ok
    else
      {:error, :invalid_issuer}
    end
  end

  defp validate_issuer(_issuer), do: {:error, :missing_issuer}

  defp validate_non_empty(value, _error) when is_binary(value) and value != "", do: :ok
  defp validate_non_empty(_value, error), do: {:error, error}

  defp validate_algorithms(algorithms) when is_list(algorithms) and algorithms != [] do
    if Enum.all?(algorithms, &(&1 in @supported_algorithms)) do
      :ok
    else
      {:error, :invalid_signing_algorithms}
    end
  end

  defp validate_algorithms(_algorithms), do: {:error, :invalid_signing_algorithms}

  defp fetch_discovery(config) do
    discovery_url =
      String.trim_trailing(config.issuer, "/") <> "/.well-known/openid-configuration"

    with {:ok, document} <- request_json(:get, discovery_url, [], config),
         :ok <- validate_discovery(document, config) do
      {:ok, document}
    end
  end

  defp validate_discovery(document, config) do
    required_endpoints = ~w(authorization_endpoint token_endpoint jwks_uri)

    cond do
      document["issuer"] != config.issuer ->
        {:error, :issuer_mismatch}

      not Enum.all?(required_endpoints, &valid_provider_endpoint?(document[&1], config)) ->
        {:error, :invalid_discovery_endpoint}

      is_binary(document["end_session_endpoint"]) and
          not valid_provider_endpoint?(document["end_session_endpoint"], config) ->
        {:error, :invalid_discovery_endpoint}

      is_binary(document["userinfo_endpoint"]) and
          not valid_provider_endpoint?(document["userinfo_endpoint"], config) ->
        {:error, :invalid_discovery_endpoint}

      "S256" not in List.wrap(document["code_challenge_methods_supported"]) ->
        {:error, :pkce_not_supported}

      not signing_algorithm_supported?(document, config) ->
        {:error, :signing_algorithm_not_supported}

      true ->
        :ok
    end
  end

  defp signing_algorithm_supported?(document, config) do
    case document["id_token_signing_alg_values_supported"] do
      nil ->
        true

      algorithms when is_list(algorithms) ->
        Enum.any?(config.allowed_algorithms, &(&1 in algorithms))

      _other ->
        false
    end
  end

  defp valid_provider_endpoint?(endpoint, config) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo) and
      is_nil(uri.fragment) and same_origin?(uri, config.issuer_uri)
  end

  defp valid_provider_endpoint?(_endpoint, _config), do: false

  defp same_origin?(left, right) do
    String.downcase(left.host) == String.downcase(right.host) and
      effective_port(left) == effective_port(right)
  end

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443

  defp exchange_code(code, session_state, discovery, config) do
    credentials =
      URI.encode_www_form(config.client_id) <>
        ":" <> URI.encode_www_form(config.client_secret)

    options = [
      auth: {:basic, credentials},
      form: %{
        "client_id" => config.client_id,
        "code" => code,
        "code_verifier" => session_state["code_verifier"],
        "grant_type" => "authorization_code",
        "redirect_uri" => session_state["redirect_uri"]
      }
    ]

    request_json(:post, discovery["token_endpoint"], options, config)
  end

  defp validate_id_token(id_token, _token_response, _session_state, _discovery, _config)
       when byte_size(id_token) > @max_id_token_bytes,
       do: {:error, :id_token_too_large}

  defp validate_id_token(id_token, token_response, session_state, discovery, config) do
    case String.split(id_token, ".", parts: 6) do
      [_header, _claims, _signature] ->
        validate_signed_id_token(id_token, session_state, discovery, config)

      [_header, _encrypted_key, _iv, _ciphertext, _tag] ->
        fetch_userinfo_claims(token_response, discovery, config)

      _other ->
        {:error, :invalid_id_token_format}
    end
  end

  defp fetch_userinfo_claims(token_response, discovery, config) do
    with {:ok, endpoint} <-
           required_binary(discovery, "userinfo_endpoint", :userinfo_not_supported),
         {:ok, access_token} <-
           required_binary(token_response, "access_token", :missing_access_token),
         :ok <- validate_bearer_token_type(token_response),
         {:ok, claims} <-
           request_json(:get, endpoint, [auth: {:bearer, access_token}], config),
         :ok <- non_empty_claim(claims, "sub", :invalid_token_subject) do
      {:ok, Map.put(claims, "iss", config.issuer)}
    end
  end

  defp validate_bearer_token_type(%{"token_type" => token_type})
       when is_binary(token_type) do
    if String.downcase(token_type) == "bearer",
      do: :ok,
      else: {:error, :invalid_access_token_type}
  end

  defp validate_bearer_token_type(_token_response),
    do: {:error, :invalid_access_token_type}

  defp validate_signed_id_token(id_token, session_state, discovery, config) do
    try do
      with {:ok, header} <- token_header(id_token),
           {:ok, algorithm} <- allowed_algorithm(header, config),
           {:ok, jwks} <- request_json(:get, discovery["jwks_uri"], [], config),
           {:ok, key} <- signing_key(jwks, header, algorithm),
           {:ok, claims} <- verify_signature(key, algorithm, id_token),
           :ok <- validate_claims(claims, session_state, config) do
        {:ok, claims}
      end
    rescue
      _exception -> {:error, :id_token_validation_exception}
    catch
      _kind, _reason -> {:error, :id_token_validation_exception}
    end
  end

  defp token_header(id_token) do
    case id_token |> JOSE.JWT.peek_protected() |> JOSE.JWS.to_map() do
      {_metadata, header} when is_map(header) -> {:ok, header}
      _other -> {:error, :invalid_id_token_header}
    end
  end

  defp allowed_algorithm(%{"alg" => algorithm} = header, config)
       when algorithm in @supported_algorithms do
    cond do
      algorithm not in config.allowed_algorithms -> {:error, :invalid_token_algorithm}
      Map.get(header, "typ") not in [nil, "JWT"] -> {:error, :invalid_token_type}
      true -> {:ok, algorithm}
    end
  end

  defp allowed_algorithm(_header, _config), do: {:error, :invalid_token_algorithm}

  defp signing_key(%{"keys" => keys}, %{"kid" => kid}, algorithm)
       when is_list(keys) and is_binary(kid) and kid != "" do
    case Enum.filter(keys, &matching_signing_key?(&1, kid, algorithm)) do
      [key] -> {:ok, JOSE.JWK.from_map(key)}
      _other -> {:error, :signing_key_not_found}
    end
  end

  defp signing_key(_jwks, _header, _algorithm), do: {:error, :signing_key_not_found}

  defp matching_signing_key?(key, kid, algorithm) when is_map(key) do
    key["kid"] == kid and key["kty"] == "RSA" and key["use"] in [nil, "sig"] and
      key["alg"] in [nil, algorithm]
  end

  defp matching_signing_key?(_key, _kid, _algorithm), do: false

  defp verify_signature(key, algorithm, id_token) do
    case JOSE.JWT.verify_strict(key, [algorithm], id_token) do
      {true, %JOSE.JWT{fields: claims}, _jws} when is_map(claims) -> {:ok, claims}
      _other -> {:error, :invalid_token_signature}
    end
  end

  defp validate_claims(claims, session_state, config) do
    current_time = now()

    with :ok <- exact_claim(claims, "iss", config.issuer, :invalid_token_issuer),
         :ok <- audience_claim(claims, config.client_id),
         :ok <- future_expiry(claims["exp"], current_time),
         :ok <- valid_issued_at(claims["iat"], current_time, config),
         :ok <- exact_secure_claim(claims, "nonce", session_state["nonce"], :invalid_token_nonce),
         :ok <- non_empty_claim(claims, "sub", :invalid_token_subject) do
      :ok
    end
  end

  defp exact_claim(claims, key, expected, _error)
       when is_map_key(claims, key) and :erlang.map_get(key, claims) == expected,
       do: :ok

  defp exact_claim(_claims, _key, _expected, error), do: {:error, error}

  defp exact_secure_claim(claims, key, expected, error) do
    case Map.get(claims, key) do
      actual when is_binary(actual) -> secure_compare(actual, expected, error)
      _other -> {:error, error}
    end
  end

  defp audience_claim(%{"aud" => audience} = claims, client_id) when is_binary(audience) do
    if audience == client_id and Map.get(claims, "azp", client_id) == client_id,
      do: :ok,
      else: {:error, :invalid_token_audience}
  end

  defp audience_claim(%{"aud" => audiences} = claims, client_id) when is_list(audiences) do
    if client_id in audiences and Map.get(claims, "azp") == client_id,
      do: :ok,
      else: {:error, :invalid_token_audience}
  end

  defp audience_claim(_claims, _client_id), do: {:error, :invalid_token_audience}

  defp future_expiry(expiry, current_time) when is_integer(expiry) and expiry > current_time,
    do: :ok

  defp future_expiry(_expiry, _current_time), do: {:error, :expired_id_token}

  defp valid_issued_at(issued_at, current_time, config)
       when is_integer(issued_at) and
              issued_at <= current_time + config.clock_skew_seconds and
              issued_at >= current_time - config.max_token_age_seconds,
       do: :ok

  defp valid_issued_at(_issued_at, _current_time, _config), do: {:error, :invalid_token_issued_at}

  defp non_empty_claim(claims, key, error) do
    case Map.get(claims, key) do
      value when is_binary(value) and value != "" -> :ok
      _other -> {:error, error}
    end
  end

  defp identity_from_claims(claims) do
    email = optional_binary(claims["email"])
    display_name = optional_binary(claims["name"] || claims["preferred_username"])

    {:ok,
     %Identity{
       issuer: claims["iss"],
       subject: claims["sub"],
       email: email,
       display_name: display_name
     }}
  end

  defp optional_binary(value) when is_binary(value) and value != "", do: value
  defp optional_binary(_value), do: nil

  defp validate_flow(session_state, config) do
    created_at = session_state["created_at"]
    current_time = now()

    fields_valid? =
      Enum.all?(~w(state nonce code_verifier redirect_uri), fn key ->
        value = session_state[key]
        is_binary(value) and value != ""
      end)

    if fields_valid? and is_integer(created_at) and
         created_at <= current_time + config.clock_skew_seconds and
         created_at >= current_time - config.flow_ttl_seconds do
      :ok
    else
      {:error, :expired_flow}
    end
  end

  defp validate_state(callback_params, session_state) do
    case callback_params["state"] do
      state when is_binary(state) -> secure_compare(state, session_state["state"], :invalid_state)
      _other -> {:error, :invalid_state}
    end
  end

  defp validate_provider_response(%{"error" => "access_denied"}), do: {:error, :access_denied}

  defp validate_provider_response(%{"error" => error}) when is_binary(error),
    do: {:error, :provider_error}

  defp validate_provider_response(_callback_params), do: :ok

  defp validate_application_uri(uri) do
    parsed = URI.parse(uri)

    if parsed.scheme in ["http", "https"] and is_binary(parsed.host) and
         is_nil(parsed.userinfo) and is_nil(parsed.fragment) do
      :ok
    else
      {:error, :invalid_callback_uri}
    end
  end

  defp request_json(method, url, options, config) do
    base_options = [
      method: method,
      url: url,
      decode_body: false,
      redirect: false,
      retry: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000]
    ]

    request_options =
      base_options
      |> Keyword.merge(config.http_options)
      |> Keyword.merge(options)

    case Req.request(request_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        validate_json_body(body)

      {:ok, %Req.Response{}} ->
        {:error, :provider_http_error}

      {:error, _exception} ->
        {:error, :provider_unavailable}
    end
  end

  defp validate_json_body(body) when is_map(body) do
    if body |> Jason.encode_to_iodata!() |> IO.iodata_length() <= @max_json_bytes,
      do: {:ok, body},
      else: {:error, :provider_response_too_large}
  end

  defp validate_json_body(body) when is_binary(body) and byte_size(body) <= @max_json_bytes do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> {:error, :invalid_provider_response}
    end
  end

  defp validate_json_body(_body), do: {:error, :invalid_provider_response}

  defp required_binary(map, key, error) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, error}
    end
  end

  defp append_query(uri, params) do
    parsed = URI.parse(uri)
    existing_params = if parsed.query, do: URI.decode_query(parsed.query), else: %{}
    query = existing_params |> Map.merge(params) |> URI.encode_query()
    parsed |> Map.put(:query, query) |> URI.to_string()
  end

  defp maybe_put_id_token_hint(params, hint) when is_binary(hint) and hint != "",
    do: Map.put(params, "id_token_hint", hint)

  defp maybe_put_id_token_hint(params, _hint), do: params

  defp pkce_challenge(code_verifier) do
    :crypto.hash(:sha256, code_verifier)
    |> Base.url_encode64(padding: false)
  end

  defp random_urlsafe(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp secure_compare(left, right, error)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    if Plug.Crypto.secure_compare(left, right), do: :ok, else: {:error, error}
  end

  defp secure_compare(_left, _right, error), do: {:error, error}

  defp now, do: System.system_time(:second)
end
