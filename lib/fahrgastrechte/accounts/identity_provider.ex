defmodule Fahrgastrechte.Accounts.IdentityProvider do
  @moduledoc """
  Integration boundary for the configured OpenID Connect provider.

  Implementations are responsible for authorization-code exchange and for
  validating issuer, signature, audience, expiry, state and nonce. Accounts
  only accepts the resulting trusted authenticated session.
  """

  alias Fahrgastrechte.Accounts.AuthenticatedSession

  @callback authorization_request(callback_uri :: String.t()) ::
              {:ok, %{uri: String.t(), session_state: map()}} | {:error, term()}

  @callback validate_callback(callback_params :: map(), session_state :: map()) ::
              {:ok, AuthenticatedSession.t()} | {:error, term()}

  @callback logout_uri(id_token_hint :: String.t() | nil, return_to :: String.t()) ::
              {:ok, String.t()} | {:error, term()}
end
