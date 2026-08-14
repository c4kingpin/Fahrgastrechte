defmodule Fahrgastrechte.TestIdentityProvider do
  @moduledoc false

  @behaviour Fahrgastrechte.Accounts.IdentityProvider

  alias Fahrgastrechte.Accounts.AuthenticatedSession
  alias Fahrgastrechte.Accounts.Identity

  @impl true
  def authorization_request(callback_uri) do
    {:ok,
     %{
       uri:
         "https://identity.example.invalid/authorize?" <>
           URI.encode_query(%{"redirect_uri" => callback_uri, "state" => "test-state"}),
       session_state: %{
         "state" => "test-state",
         "nonce" => "test-nonce",
         "code_verifier" => "test-code-verifier",
         "redirect_uri" => callback_uri,
         "created_at" => System.system_time(:second)
       }
     }}
  end

  @impl true
  def validate_callback(
        %{"code" => "valid-code", "state" => "test-state"},
        %{"state" => "test-state"}
      ) do
    {:ok,
     %AuthenticatedSession{
       identity: %Identity{
         issuer: "https://identity.example.invalid/application/fahrgastrechte/",
         subject: "controller-test-user",
         email: "controller@example.invalid",
         display_name: "Controller Test"
       },
       expires_at: System.system_time(:second) + 3_600,
       id_token: "test-id-token"
     }}
  end

  def validate_callback(
        %{"code" => "provider-error", "state" => "test-state"},
        %{"state" => "test-state"}
      ),
      do: {:error, :provider_http_error}

  def validate_callback(_params, _session_state), do: {:error, :invalid_state}

  @impl true
  def logout_uri(id_token_hint, return_to) do
    {:ok,
     "https://identity.example.invalid/end-session?" <>
       URI.encode_query(%{"id_token_hint" => id_token_hint || "", "return_to" => return_to})}
  end
end
