defmodule Fahrgastrechte.AccountsTest do
  use Fahrgastrechte.DataCase, async: true

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.Profile
  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Repo

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures

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
      refute Accounts.profile_complete?(updated_profile)
      assert :iban in Accounts.profile_missing_fields(updated_profile)
    end

    test "detects modified ciphertext" do
      scope = scope_fixture()
      assert {:ok, profile} = Accounts.update_profile(scope, valid_profile_attributes())

      profile
      |> Ecto.Changeset.change(iban_ciphertext: profile.iban_ciphertext <> <<0>>)
      |> Repo.update!()

      assert {:error, :invalid_ciphertext} = Accounts.get_profile(scope)
      assert {:error, :invalid_ciphertext} = Accounts.profile_completeness(scope)
    end

    test "rejects ciphertext moved to another user's profile" do
      scope = scope_fixture()
      other_scope = scope_fixture()

      assert {:ok, profile} = Accounts.update_profile(scope, valid_profile_attributes())

      assert {:ok, other_profile} =
               Accounts.update_profile(other_scope, valid_profile_attributes())

      other_profile
      |> Ecto.Changeset.change(
        iban_ciphertext: profile.iban_ciphertext,
        bank_data_key_version: profile.bank_data_key_version
      )
      |> Repo.update!()

      assert {:error, :invalid_ciphertext} = Accounts.get_profile(other_scope)
    end

    test "reads records written before the additional data was bound to the user" do
      scope = scope_fixture()
      assert {:ok, profile} = Accounts.update_profile(scope, valid_profile_attributes())

      legacy_ciphertext =
        legacy_encrypt(valid_profile_attributes()["iban"], :iban, profile.bank_data_key_version)

      profile
      |> Ecto.Changeset.change(iban_ciphertext: legacy_ciphertext)
      |> Repo.update!()

      assert {:ok, loaded} = Accounts.get_profile(scope)
      assert loaded.iban == valid_profile_attributes()["iban"]
    end

    test "validates IBAN before encryption" do
      scope = scope_fixture()

      assert {:error, changeset} =
               Accounts.update_profile(scope, valid_profile_attributes(%{"iban" => "DE00123"}))

      assert %{iban: [_message]} = errors_on(changeset)
    end

    test "reports completeness from decrypted required fields" do
      scope = scope_fixture()

      assert {:ok, initial} = Accounts.profile_completeness(scope)
      refute initial.complete?
      assert :first_name in initial.missing_fields

      assert {:ok, profile} = Accounts.update_profile(scope, valid_profile_attributes())
      assert Accounts.profile_complete?(profile)
      assert Accounts.profile_missing_fields(profile) == []
    end

    test "a scope cannot be replaced by a bare user id" do
      user = user_fixture()

      assert {:error, :not_authenticated} = Accounts.get_profile(user.id)
      refute function_exported?(Accounts, :get_profile, 0)
      assert %Scope{} = Scope.for_user(user)
    end
  end

  describe "profile changes and ready claims" do
    test "a relevant field change demotes a ready claim back to draft" do
      scope = scope_fixture()
      assert {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())
      claim = claim_fixture(scope)
      assert {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      assert ready.generated_at

      assert {:ok, _updated} =
               Accounts.update_profile(
                 scope,
                 valid_profile_attributes(%{"iban" => "DE02120300000000202051"})
               )

      assert {:ok, reopened} = Claims.get_claim(scope, claim.id)
      assert reopened.status == :draft
      assert reopened.generated_at == nil
    end

    test "leaves a sent claim untouched" do
      scope = scope_fixture()
      assert {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())
      claim = claim_fixture(scope)
      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      {:ok, sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)

      assert {:ok, _updated} =
               Accounts.update_profile(
                 scope,
                 valid_profile_attributes(%{"iban" => "DE02120300000000202051"})
               )

      assert {:ok, unchanged} = Claims.get_claim(scope, claim.id)
      assert unchanged.status == :sent
      assert unchanged.sent_at == sent.sent_at
    end

    test "leaves a completed claim untouched" do
      scope = scope_fixture()
      assert {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())
      claim = claim_fixture(scope)
      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      {:ok, sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)
      {:ok, completed} = Claims.transition_claim(scope, claim.id, :completed, sent.lock_version)

      assert {:ok, _updated} =
               Accounts.update_profile(
                 scope,
                 valid_profile_attributes(%{"iban" => "DE02120300000000202051"})
               )

      assert {:ok, unchanged} = Claims.get_claim(scope, claim.id)
      assert unchanged.status == :completed
      assert unchanged.completed_at == completed.completed_at
    end

    test "a non-relevant field change does not reset a ready claim" do
      scope = scope_fixture()
      assert {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())
      claim = claim_fixture(scope)
      assert {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)

      assert {:ok, _updated} =
               Accounts.update_profile(
                 scope,
                 valid_profile_attributes(%{
                   "phone_number" => "+49 30 000000",
                   "title" => "Dr."
                 })
               )

      assert {:ok, unchanged} = Claims.get_claim(scope, claim.id)
      assert unchanged.status == :ready
      assert unchanged.generated_at == ready.generated_at
    end

    test "a single profile change demotes every ready claim of this user" do
      scope = scope_fixture()
      assert {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())
      first_claim = claim_fixture(scope, %{"origin" => "Köln Hbf"})
      second_claim = claim_fixture(scope, %{"origin" => "München Hbf"})

      {:ok, _first_ready} =
        Claims.transition_claim(scope, first_claim.id, :ready, first_claim.lock_version)

      {:ok, _second_ready} =
        Claims.transition_claim(scope, second_claim.id, :ready, second_claim.lock_version)

      assert {:ok, _updated} =
               Accounts.update_profile(
                 scope,
                 valid_profile_attributes(%{"iban" => "DE02120300000000202051"})
               )

      assert {:ok, first_reopened} = Claims.get_claim(scope, first_claim.id)
      assert {:ok, second_reopened} = Claims.get_claim(scope, second_claim.id)
      assert first_reopened.status == :draft
      assert second_reopened.status == :draft
    end
  end

  # Reproduces the additional data used before it was bound to the owning user.
  defp legacy_encrypt(value, field, version) do
    key =
      :fahrgastrechte
      |> Application.fetch_env!(Fahrgastrechte.Accounts.BankDataCipher)
      |> Keyword.fetch!(:keys)
      |> Map.fetch!(version)

    nonce = :crypto.strong_rand_bytes(12)
    aad = "fahrgastrechte:accounts:bank-data:v#{version}:#{field}"

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, value, aad, true)

    nonce <> tag <> ciphertext
  end
end
