defmodule Fahrgastrechte.Accounts.Identity do
  @moduledoc """
  The trusted output of an identity provider.

  The Authentik adapter verifies the complete OIDC response before it
  constructs an identity and hands it to `Fahrgastrechte.Accounts`.
  """

  @enforce_keys [:issuer, :subject]
  defstruct [:issuer, :subject, :email, :display_name]

  @type t :: %__MODULE__{
          issuer: String.t(),
          subject: String.t(),
          email: String.t() | nil,
          display_name: String.t() | nil
        }

  @doc """
  Builds the explicit local identity used for development without Authentik.
  """
  @spec development(map()) :: {:ok, t()} | {:error, :invalid_development_identity}
  def development(%{issuer: issuer, subject: subject} = attrs)
      when is_binary(issuer) and byte_size(issuer) > 0 and is_binary(subject) and
             byte_size(subject) > 0 do
    {:ok,
     %__MODULE__{
       issuer: issuer,
       subject: subject,
       email: Map.get(attrs, :email),
       display_name: Map.get(attrs, :display_name)
     }}
  end

  def development(_attrs), do: {:error, :invalid_development_identity}
end
