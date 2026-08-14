defmodule Fahrgastrechte.Accounts do
  @moduledoc """
  Identity mapping and traveller profiles.

  All profile functions are scoped to the current user. The only unscoped user
  lookup is reserved for reconstructing `current_scope` from a signed session.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Fahrgastrechte.Accounts.BankDataCipher
  alias Fahrgastrechte.Accounts.Identity
  alias Fahrgastrechte.Accounts.Profile
  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Repo

  @doc """
  Finds or creates the local user for a trusted provider identity.

  Email and display name are refreshed on repeat sign-in, but never participate
  in identity matching.
  """
  @spec register_identity(Identity.t()) :: {:ok, User.t()} | {:error, Changeset.t()}
  def register_identity(%Identity{} = identity) do
    Multi.new()
    |> Multi.insert(
      :user,
      User.identity_changeset(%User{}, identity),
      conflict_target: [:issuer, :subject],
      on_conflict: {:replace, [:email, :display_name, :updated_at]},
      returning: true
    )
    |> Multi.insert(
      :profile,
      fn %{user: user} -> Profile.changeset(%Profile{user_id: user.id}, %{}) end,
      conflict_target: [:user_id],
      on_conflict: :nothing
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, _operation, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc false
  def scope_for_user_id(user_id) when is_integer(user_id) do
    User |> Repo.get(user_id) |> Scope.for_user()
  end

  def scope_for_user_id(_user_id), do: nil

  @doc """
  Loads only the current user's traveller profile.
  """
  @spec get_profile(Scope.t()) :: {:ok, Profile.t()} | {:error, atom()}
  def get_profile(%Scope{user: %User{id: user_id}}) do
    case Repo.one(from profile in Profile, where: profile.user_id == ^user_id) do
      nil -> {:error, :not_found}
      profile -> decrypt_profile(profile)
    end
  end

  def get_profile(_scope), do: {:error, :not_authenticated}

  @doc """
  Returns a profile changeset for the current user.
  """
  @spec change_profile(Scope.t() | Profile.t(), map()) :: Changeset.t() | {:error, atom()}
  def change_profile(profile_or_scope, attrs \\ %{})

  def change_profile(%Profile{} = profile, attrs), do: Profile.changeset(profile, attrs)

  def change_profile(%Scope{} = scope, attrs) do
    with {:ok, profile} <- get_profile(scope) do
      Profile.changeset(profile, attrs)
    end
  end

  def change_profile(_scope, _attrs), do: {:error, :not_authenticated}

  @doc """
  Updates only the current user's profile.
  """
  @spec update_profile(Scope.t(), map()) ::
          {:ok, Profile.t()} | {:error, Changeset.t() | atom()}
  def update_profile(%Scope{} = scope, attrs) do
    with {:ok, profile} <- get_profile(scope) do
      profile
      |> Profile.changeset(attrs)
      |> encrypt_bank_changes()
      |> Repo.update()
      |> case do
        {:ok, updated_profile} -> decrypt_profile(updated_profile)
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def update_profile(_scope, _attrs), do: {:error, :not_authenticated}

  @doc """
  Loads and decrypts the profile once and returns its explicit completeness state.
  """
  @spec profile_completeness(Scope.t()) :: {:ok, map()} | {:error, atom()}
  def profile_completeness(%Scope{} = scope) do
    with {:ok, profile} <- get_profile(scope) do
      missing_fields = profile_missing_fields(profile)

      {:ok,
       %{
         profile: profile,
         missing_fields: missing_fields,
         complete?: missing_fields == []
       }}
    end
  end

  def profile_completeness(_scope), do: {:error, :not_authenticated}

  @doc "Reports whether every field needed for a Fahrgastrechte form is present."
  @spec profile_complete?(Profile.t()) :: boolean()
  def profile_complete?(%Profile{} = profile), do: profile_missing_fields(profile) == []

  @doc """
  Lists the required profile fields which are still empty.
  """
  @spec profile_missing_fields(Profile.t()) :: [atom()]
  def profile_missing_fields(%Profile{} = profile) do
    Enum.filter(Profile.required_fields(), fn field ->
      value = Map.fetch!(profile, field)
      is_nil(value) or value == ""
    end)
  end

  defp encrypt_bank_changes(%Changeset{valid?: false} = changeset), do: changeset

  defp encrypt_bank_changes(changeset) do
    bank_fields = [:iban, :bic]

    if Enum.any?(bank_fields, &(Changeset.fetch_change(changeset, &1) != :error)) do
      changeset =
        Enum.reduce_while(bank_fields, changeset, fn field, current_changeset ->
          case Changeset.get_field(current_changeset, field) do
            nil ->
              {:cont, Changeset.put_change(current_changeset, :"#{field}_ciphertext", nil)}

            value ->
              encrypt_bank_field(current_changeset, field, value)
          end
        end)

      if Changeset.get_field(changeset, :iban) == nil and
           Changeset.get_field(changeset, :bic) == nil do
        Changeset.put_change(changeset, :bank_data_key_version, nil)
      else
        changeset
      end
    else
      changeset
    end
  end

  defp encrypt_bank_field(changeset, field, value) do
    case BankDataCipher.encrypt(value, field) do
      {:ok, ciphertext, version} ->
        changeset =
          changeset
          |> Changeset.put_change(:"#{field}_ciphertext", ciphertext)
          |> Changeset.put_change(:bank_data_key_version, version)

        {:cont, changeset}

      {:error, :encryption_key_unavailable} ->
        {:halt,
         Changeset.add_error(changeset, field, "kann derzeit nicht sicher gespeichert werden")}
    end
  end

  defp decrypt_profile(%Profile{bank_data_key_version: nil} = profile), do: {:ok, profile}

  defp decrypt_profile(%Profile{} = profile) do
    with {:ok, iban} <-
           decrypt_optional(profile.iban_ciphertext, profile.bank_data_key_version, :iban),
         {:ok, bic} <-
           decrypt_optional(profile.bic_ciphertext, profile.bank_data_key_version, :bic) do
      {:ok, %{profile | iban: iban, bic: bic}}
    end
  end

  defp decrypt_optional(nil, _version, _field), do: {:ok, nil}

  defp decrypt_optional(ciphertext, version, field),
    do: BankDataCipher.decrypt(ciphertext, version, field)
end
