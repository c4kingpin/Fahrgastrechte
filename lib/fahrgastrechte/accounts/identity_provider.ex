defmodule Fahrgastrechte.Accounts.IdentityProvider do
  @moduledoc """
  Integration boundary for the future Authentik OIDC adapter.

  Implementations are responsible for authorization-code exchange and for
  validating issuer, signature, audience, expiry, state and nonce. Accounts
  only accepts the resulting trusted `Identity`.
  """

  alias Fahrgastrechte.Accounts.Identity

  @callback validate_callback(callback_params :: map(), session_state :: map()) ::
              {:ok, Identity.t()} | {:error, term()}

  @callback logout_uri(Identity.t(), return_to :: URI.t()) ::
              {:ok, URI.t()} | {:error, term()}
end
