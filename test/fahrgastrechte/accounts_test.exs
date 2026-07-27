defmodule Fahrgastrechte.AccountsTest do
  use Fahrgastrechte.DataCase, async: true

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.Profile
  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Repo

  import Fahrgastrechte.AccountsFixtures

  describe "register_identity/1" do
    test "creates a user and exactly one profile on first and repeat registration" do
      identity = identity_fixture()

      assert {:ok, first_user} = Accounts.register_identity(identity)

      assert {:ok, second_user} =
               Accounts.register_identity(%{identity | display_name: "Aktualisiert"})

      assert first_user.id == second_user.id
      assert second_user.display_name == "Aktualisiert"
      assert Repo.aggregate(Profile, :count) == 1
    end

    test "does not confuse the same email with a different subject" do
      email = "shared@example.invalid"

      assert {:ok, first_user} = Accounts.register_identity(identity_fixture(%{email: email}))
      assert {:ok, second_user} = Accounts.register_identity(identity_fixture(%{email: email}))

      refute first_user.id == second_user.id
      refute first_user.subject == second_user.subject
    end
  end

  describe "traveller profiles" do
    test "loads and updates only the profile belonging to current_scope" do
      first_scope = scope_fixture()
      second_scope = scope_fixture()

      assert {:ok, first_profile} =
               Accounts.update_profile(
                 first_scope,
                 valid_profile_attributes(%{"first_name" => "Erika"})
               )

      assert {:ok, second_profile} =
               Accounts.update_profile(
                 second_scope,
                 valid_profile_attributes(%{"first_name" => "Max"})
               )

      assert first_profile.id != second_profile.id
      assert {:ok, loaded_first_profile} = Accounts.get_profile(first_scope)
      assert {:ok, loaded_second_profile} = Accounts.get_profile(second_scope)
      assert loaded_first_profile.first_name == "Erika"
      assert loaded_second_profile.first_name == "Max"
    end

    test "rejects missing scope" do
      assert {:error, :not_authenticated} = Accounts.get_profile(nil)

      assert {:error, :not_authenticated} =
               Accounts.update_profile(nil, valid_profile_attributes())
    end

    test "stores IBAN and BIC as authenticated ciphertext" do
      scope = scope_fixture()
      attrs = valid_profile_attributes()

      assert {:ok, profile} = Accounts.update_profile(scope, attrs)
      raw_profile = Repo.get!(Profile, profile.id)

      assert raw_profile.iban_ciphertext != attrs["iban"]
      assert raw_profile.bic_ciphertext != attrs["bic"]
      assert :binary.match(raw_profile.iban_ciphertext, attrs["iban"]) == :nomatch
      assert :binary.match(raw_profile.bic_ciphertext, attrs["bic"]) == :nomatch
      assert raw_profile.bank_data_key_version == 1

      assert {:ok, loaded_profile} = Accounts.get_profile(scope)
      assert loaded_profile.iban == attrs["iban"]
      assert loaded_profile.bic == attrs["bic"]
    end

    test "removes ciphertext when a bank field is cleared" do
      scope = scope_fixture()
      assert {:ok, profile} = Accounts.update_profile(scope, valid_profile_attributes())

      assert {:ok, updated_profile} = Accounts.update_profile(scope, %{"iban" => ""})
      raw_profile = Repo.get!(Profile, profile.id)

      assert updated_profile.iban == nil
      assert raw_profile.iban_ciphertext == nil
      assert is_binary(raw_profile.bic_ciphertext)
      assert raw_profile.bank_data_key_version == 1
      refute Accounts.profile_complete?(scope)
      assert :iban in Accounts.profile_missing_fields(scope)
    end

    test "detects modified ciphertext" do
      scope = scope_fixture()
      assert {:ok, profile} = Accounts.update_profile(scope, valid_profile_attributes())

      profile
      |> Ecto.Changeset.change(iban_ciphertext: profile.iban_ciphertext <> <<0>>)
      |> Repo.update!()

      assert {:error, :invalid_ciphertext} = Accounts.get_profile(scope)
    end

    test "validates IBAN before encryption" do
      scope = scope_fixture()

      assert {:error, changeset} =
               Accounts.update_profile(scope, valid_profile_attributes(%{"iban" => "DE00123"}))

      assert %{iban: [_message]} = errors_on(changeset)
    end

    test "reports completeness from decrypted required fields" do
      scope = scope_fixture()

      refute Accounts.profile_complete?(scope)
      assert :first_name in Accounts.profile_missing_fields(scope)

      assert {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())
      assert Accounts.profile_complete?(scope)
      assert Accounts.profile_missing_fields(scope) == []
    end

    test "a scope cannot be replaced by a bare user id" do
      user = user_fixture()

      assert {:error, :not_authenticated} = Accounts.get_profile(user.id)
      refute function_exported?(Accounts, :get_profile, 0)
      assert %Scope{} = Scope.for_user(user)
    end
  end
end
