defmodule Fahrgastrechte.E2EIdentityProvider do
  @moduledoc """
  Identity provider for browser tests that completes the OIDC round trip locally.

  The authorization URI points straight back to the app's own callback, as if
  the person had already approved the login at the provider, so the browser
  walks the real `/anmelden` → `/auth/callback` → `/abmelden` flow without
  reaching an external host.
  """

  @behaviour Fahrgastrechte.Accounts.IdentityProvider

  alias Fahrgastrechte.Accounts.AuthenticatedSession
  alias Fahrgastrechte.Accounts.Identity

  @state "e2e-state"

  def identity do
    %Identity{
      issuer: "https://identity.example.invalid/application/fahrgastrechte/",
      subject: "e2e-browser-user",
      email: "browser@example.invalid",
      display_name: "Browser Testperson"
    }
  end

  @impl true
  def authorization_request(callback_uri) do
    {:ok,
     %{
       uri: callback_uri <> "?" <> URI.encode_query(%{"code" => "e2e-code", "state" => @state}),
       session_state: %{"state" => @state, "created_at" => System.system_time(:second)}
     }}
  end

  @impl true
  def validate_callback(%{"code" => "e2e-code", "state" => @state}, %{"state" => @state}) do
    {:ok,
     %AuthenticatedSession{
       identity: identity(),
       expires_at: System.system_time(:second) + 3_600,
       id_token: "e2e-id-token"
     }}
  end

  def validate_callback(%{"error" => "access_denied"}, _session_state),
    do: {:error, :access_denied}

  def validate_callback(_params, _session_state), do: {:error, :invalid_state}

  @impl true
  def logout_uri(_id_token_hint, return_to), do: {:ok, return_to}
end
