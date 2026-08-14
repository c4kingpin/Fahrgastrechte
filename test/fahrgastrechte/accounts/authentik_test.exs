defmodule Fahrgastrechte.Accounts.AuthentikTest do
  use ExUnit.Case, async: false

  alias Fahrgastrechte.Accounts.Authentik

  @issuer "https://identity.example.invalid/application/o/fahrgastrechte/"
  @client_id "fahrgastrechte-client"
  @client_secret "test-client-secret"
  @callback_uri "https://app.example.invalid/auth/callback"

  setup_all do
    {:ok, signing_key: JOSE.JWK.generate_key({:rsa, 2048})}
  end

  setup do
    previous_config = Application.get_env(:fahrgastrechte, Authentik)
    put_provider_config([])

    on_exit(fn ->
      Application.put_env(:fahrgastrechte, Authentik, previous_config)
    end)

    :ok
  end

  test "builds an authorization-code request with PKCE, state and nonce" do
    stub_name = {__MODULE__, :authorization}
    put_provider_config(plug: {Req.Test, stub_name})

    Req.Test.expect(stub_name, fn conn ->
      assert conn.request_path == "/application/o/fahrgastrechte/.well-known/openid-configuration"
      Req.Test.json(conn, discovery_document())
    end)

    assert {:ok, %{uri: uri, session_state: session_state}} =
             Authentik.authorization_request(@callback_uri)

    query = uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["response_type"] == "code"
    assert query["scope"] == "openid profile email"
    assert query["state"] == session_state["state"]
    assert query["nonce"] == session_state["nonce"]
    assert query["code_challenge_method"] == "S256"
    assert query["redirect_uri"] == @callback_uri
    assert byte_size(session_state["code_verifier"]) >= 43

    assert query["code_challenge"] ==
             :crypto.hash(:sha256, session_state["code_verifier"])
             |> Base.url_encode64(padding: false)
  end

  test "exchanges the code and accepts a fully valid signed ID token", %{signing_key: signing_key} do
    test_pid = self()
    stub_name = {__MODULE__, :valid_callback}
    put_provider_config(plug: {Req.Test, stub_name})
    token = signed_token(signing_key, valid_claims())

    stub_provider(stub_name, signing_key, token, fn token_conn ->
      {:ok, body, token_conn} = Plug.Conn.read_body(token_conn)
      send(test_pid, {:token_request, URI.decode_query(body), token_conn.req_headers})
      token_conn
    end)

    assert {:ok, authenticated_session} =
             Authentik.validate_callback(valid_callback(), valid_flow())

    assert authenticated_session.identity.issuer == @issuer
    assert authenticated_session.identity.subject == "authentik-subject"
    assert authenticated_session.identity.email == "person@example.invalid"
    assert authenticated_session.identity.display_name == "Erika Beispiel"
    assert authenticated_session.id_token == token
    assert authenticated_session.expires_at > System.system_time(:second)

    assert_receive {:token_request, params, headers}
    assert params["grant_type"] == "authorization_code"
    assert params["code"] == "valid-code"
    assert params["code_verifier"] == "test-code-verifier"
    assert params["redirect_uri"] == @callback_uri
    assert {"authorization", "Basic " <> _credentials} = List.keyfind(headers, "authorization", 0)
  end

  test "rejects a mismatched state before contacting the provider" do
    stub_name = {__MODULE__, :invalid_state}
    put_provider_config(plug: {Req.Test, stub_name})

    Req.Test.stub(stub_name, fn _conn ->
      flunk("the provider must not be contacted for an invalid state")
    end)

    assert {:error, :invalid_state} =
             Authentik.validate_callback(
               %{"code" => "valid-code", "state" => "wrong-state"},
               valid_flow()
             )
  end

  test "rejects a nonce mismatch", %{signing_key: signing_key} do
    assert_claim_error(signing_key, %{"nonce" => "wrong-nonce"}, :invalid_token_nonce, :nonce)
  end

  test "rejects a different audience", %{signing_key: signing_key} do
    assert_claim_error(
      signing_key,
      %{"aud" => "different-client"},
      :invalid_token_audience,
      :audience
    )
  end

  test "rejects expired and stale tokens", %{signing_key: signing_key} do
    current_time = System.system_time(:second)

    assert_claim_error(
      signing_key,
      %{"exp" => current_time - 1},
      :expired_id_token,
      :expiry
    )

    assert_claim_error(
      signing_key,
      %{"iat" => current_time - 700},
      :invalid_token_issued_at,
      :issued_at
    )
  end

  test "rejects a token whose signature does not match the issuer JWKS", %{
    signing_key: signing_key
  } do
    other_key = JOSE.JWK.generate_key({:rsa, 2048})
    token = signed_token(other_key, valid_claims())
    stub_name = {__MODULE__, :signature}
    put_provider_config(plug: {Req.Test, stub_name})
    stub_provider(stub_name, signing_key, token)

    assert {:error, :invalid_token_signature} =
             Authentik.validate_callback(valid_callback(), valid_flow())
  end

  test "resolves an encrypted ID token through the same-origin UserInfo endpoint", %{
    signing_key: signing_key
  } do
    stub_name = {__MODULE__, :encrypted_id_token}
    put_provider_config(plug: {Req.Test, stub_name})
    stub_provider(stub_name, signing_key, "header.encrypted-key.iv.ciphertext.tag")

    assert {:ok, authenticated_session} =
             Authentik.validate_callback(valid_callback(), valid_flow())

    assert authenticated_session.identity.issuer == @issuer
    assert authenticated_session.identity.subject == "authentik-subject"
    assert authenticated_session.identity.email == "person@example.invalid"
    assert authenticated_session.identity.display_name == "Erika Beispiel"
  end

  test "rejects malformed ID tokens with a specific diagnostic", %{signing_key: signing_key} do
    stub_name = {__MODULE__, :malformed_id_token}
    put_provider_config(plug: {Req.Test, stub_name})
    stub_provider(stub_name, signing_key, "not-a-compact-token")

    assert {:error, :invalid_id_token_format} =
             Authentik.validate_callback(valid_callback(), valid_flow())
  end

  test "rejects discovery documents from another issuer" do
    stub_name = {__MODULE__, :issuer_mismatch}
    put_provider_config(plug: {Req.Test, stub_name})

    Req.Test.stub(stub_name, fn conn ->
      document = Map.put(discovery_document(), "issuer", "https://attacker.example/")
      Req.Test.json(conn, document)
    end)

    assert {:error, :issuer_mismatch} = Authentik.authorization_request(@callback_uri)
  end

  test "rejects a UserInfo endpoint on another origin" do
    stub_name = {__MODULE__, :external_userinfo}
    put_provider_config(plug: {Req.Test, stub_name})

    Req.Test.stub(stub_name, fn conn ->
      document =
        Map.put(discovery_document(), "userinfo_endpoint", "https://attacker.example/userinfo")

      Req.Test.json(conn, document)
    end)

    assert {:error, :invalid_discovery_endpoint} = Authentik.authorization_request(@callback_uri)
  end

  test "builds RP-initiated logout from the validated discovery endpoint" do
    stub_name = {__MODULE__, :logout}
    put_provider_config(plug: {Req.Test, stub_name})

    Req.Test.stub(stub_name, fn conn -> Req.Test.json(conn, discovery_document()) end)

    assert {:ok, uri} =
             Authentik.logout_uri(
               "signed-id-token",
               "https://app.example.invalid/auth/abgemeldet"
             )

    query = uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["client_id"] == @client_id
    assert query["id_token_hint"] == "signed-id-token"
    assert query["post_logout_redirect_uri"] == "https://app.example.invalid/auth/abgemeldet"
  end

  defp assert_claim_error(signing_key, overrides, expected_error, name) do
    stub_name = {__MODULE__, name, System.unique_integer([:positive])}
    put_provider_config(plug: {Req.Test, stub_name})
    claims = Map.merge(valid_claims(), overrides)
    stub_provider(stub_name, signing_key, signed_token(signing_key, claims))

    assert {:error, ^expected_error} =
             Authentik.validate_callback(valid_callback(), valid_flow())
  end

  defp stub_provider(stub_name, signing_key, token, token_callback \\ & &1) do
    Req.Test.stub(stub_name, fn conn ->
      case conn.request_path do
        "/application/o/fahrgastrechte/.well-known/openid-configuration" ->
          Req.Test.json(conn, discovery_document())

        "/application/o/token/" ->
          conn
          |> token_callback.()
          |> Req.Test.json(%{
            "access_token" => "test-access-token",
            "id_token" => token,
            "token_type" => "Bearer"
          })

        "/application/o/fahrgastrechte/jwks/" ->
          Req.Test.json(conn, %{"keys" => [public_jwk(signing_key)]})

        "/application/o/userinfo/" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-access-token"]
          Req.Test.json(conn, Map.take(valid_claims(), ~w(email name sub)))

        other_path ->
          flunk("unexpected provider request to #{other_path}")
      end
    end)
  end

  defp signed_token(signing_key, claims) do
    signing_key
    |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "authentik-signing-key"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp public_jwk(signing_key) do
    {_metadata, jwk} = JOSE.JWK.to_public_map(signing_key)

    Map.merge(jwk, %{
      "alg" => "RS256",
      "kid" => "authentik-signing-key",
      "use" => "sig"
    })
  end

  defp valid_claims do
    current_time = System.system_time(:second)

    %{
      "aud" => @client_id,
      "email" => "person@example.invalid",
      "exp" => current_time + 300,
      "iat" => current_time,
      "iss" => @issuer,
      "name" => "Erika Beispiel",
      "nonce" => "test-nonce",
      "sub" => "authentik-subject"
    }
  end

  defp valid_callback do
    %{"code" => "valid-code", "state" => "test-state"}
  end

  defp valid_flow do
    %{
      "code_verifier" => "test-code-verifier",
      "created_at" => System.system_time(:second),
      "nonce" => "test-nonce",
      "redirect_uri" => @callback_uri,
      "state" => "test-state"
    }
  end

  defp discovery_document do
    %{
      "authorization_endpoint" => "https://identity.example.invalid/application/o/authorize/",
      "code_challenge_methods_supported" => ["S256"],
      "end_session_endpoint" =>
        "https://identity.example.invalid/application/o/fahrgastrechte/end-session/",
      "id_token_signing_alg_values_supported" => ["RS256"],
      "issuer" => @issuer,
      "jwks_uri" => "https://identity.example.invalid/application/o/fahrgastrechte/jwks/",
      "token_endpoint" => "https://identity.example.invalid/application/o/token/",
      "userinfo_endpoint" => "https://identity.example.invalid/application/o/userinfo/"
    }
  end

  defp put_provider_config(extra_options) do
    Application.put_env(
      :fahrgastrechte,
      Authentik,
      issuer: @issuer,
      client_id: @client_id,
      client_secret: @client_secret,
      allowed_algorithms: ["RS256"],
      http_options: extra_options
    )
  end
end
