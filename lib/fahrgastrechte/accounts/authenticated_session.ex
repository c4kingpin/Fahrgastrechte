defmodule Fahrgastrechte.Accounts.AuthenticatedSession do
  @moduledoc """
  Trusted result of a completed identity-provider login.

  Access and refresh tokens deliberately never cross this boundary. The ID
  token is retained only as a hint for RP-initiated logout.
  """

  alias Fahrgastrechte.Accounts.Identity

  @enforce_keys [:identity, :expires_at, :id_token]
  defstruct [:identity, :expires_at, :id_token]

  @type t :: %__MODULE__{
          identity: Identity.t(),
          expires_at: pos_integer(),
          id_token: String.t()
        }
end
