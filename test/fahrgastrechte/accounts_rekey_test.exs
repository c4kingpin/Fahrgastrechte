defmodule Fahrgastrechte.AccountsRekeyTest do
  # Rotates the process-wide cipher configuration and must not run concurrently.
  use Fahrgastrechte.DataCase, async: false

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.BankDataCipher
  alias Fahrgastrechte.Accounts.Profile
  alias Fahrgastrechte.Health
  alias Fahrgastrechte.Repo

  import Fahrgastrechte.AccountsFixtures

  setup do
    original_configuration = Application.get_env(:fahrgastrechte, BankDataCipher)

    on_exit(fn ->
      Application.put_env(:fahrgastrechte, BankDataCipher, original_configuration)
    end)

    {:ok, configuration: original_configuration}
  end

  defp rotate_to_version_two(configuration) do
    Application.put_env(:fahrgastrechte, BankDataCipher,
      active_key_version: 2,
      keys: Map.put(Keyword.fetch!(configuration, :keys), 2, :crypto.strong_rand_bytes(32))
    )
  end

  describe "rekey_bank_data/0" do
    test "keeps bank data readable across a key rotation", %{configuration: configuration} do
      scope = scope_fixture()
      attrs = valid_profile_attributes()

      assert {:ok, profile} = Accounts.update_profile(scope, attrs)
      original_ciphertext = Repo.get!(Profile, profile.id).iban_ciphertext

      rotate_to_version_two(configuration)

      # The retired key is still configured, so existing records stay readable.
      assert {:ok, before_rekey} = Accounts.get_profile(scope)
      assert before_rekey.iban == attrs["iban"]

      assert {:ok, %{rekeyed: 1}} = Accounts.rekey_bank_data()

      rekeyed = Repo.get!(Profile, profile.id)
      assert rekeyed.bank_data_key_version == 2
      assert rekeyed.iban_ciphertext != original_ciphertext

      assert {:ok, loaded} = Accounts.get_profile(scope)
      assert loaded.iban == attrs["iban"]
      assert loaded.bic == attrs["bic"]
    end

    test "leaves nothing readable behind the retired key", %{configuration: configuration} do
      scope = scope_fixture()
      assert {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())

      rotate_to_version_two(configuration)
      assert {:ok, %{rekeyed: 1}} = Accounts.rekey_bank_data()

      # Drop the retired key entirely, as an operator would after a successful run.
      Application.put_env(:fahrgastrechte, BankDataCipher,
        active_key_version: 2,
        keys: %{2 => Application.get_env(:fahrgastrechte, BankDataCipher)[:keys][2]}
      )

      assert {:ok, loaded} = Accounts.get_profile(scope)
      assert loaded.iban == valid_profile_attributes()["iban"]
    end

    test "skips profiles without stored bank data" do
      _scope = scope_fixture()

      assert {:ok, %{rekeyed: 0, skipped: 1}} = Accounts.rekey_bank_data()
    end

    test "a concurrent profile update is never overwritten by a running rekey",
         %{configuration: configuration} do
      scope = scope_fixture()
      assert {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())

      rotate_to_version_two(configuration)

      rekey_task = Task.async(fn -> Accounts.rekey_bank_data() end)

      update_task =
        Task.async(fn ->
          Accounts.update_profile(
            scope,
            valid_profile_attributes(%{"iban" => "DE02120300000000202051"})
          )
        end)

      assert {:ok, _counts} = Task.await(rekey_task, 5_000)
      assert {:ok, _updated} = Task.await(update_task, 5_000)

      assert {:ok, final} = Accounts.get_profile(scope)
      assert final.iban == "DE02120300000000202051"
    end

    test "is idempotent" do
      scope = scope_fixture()
      assert {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())

      assert {:ok, %{rekeyed: 1}} = Accounts.rekey_bank_data()
      assert {:ok, %{rekeyed: 1}} = Accounts.rekey_bank_data()

      assert {:ok, loaded} = Accounts.get_profile(scope)
      assert loaded.iban == valid_profile_attributes()["iban"]
    end

    test "reports a missing active key instead of destroying data" do
      scope = scope_fixture()
      assert {:ok, profile} = Accounts.update_profile(scope, valid_profile_attributes())
      original_ciphertext = Repo.get!(Profile, profile.id).iban_ciphertext

      Application.put_env(:fahrgastrechte, BankDataCipher, active_key_version: 99, keys: %{})

      assert {:error, :encryption_key_unavailable} = Accounts.rekey_bank_data()
      assert Repo.get!(Profile, profile.id).iban_ciphertext == original_ciphertext
    end

    test "readiness catches an installer that reverts a completed key rotation",
         %{configuration: configuration} do
      scope = scope_fixture()
      assert {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())

      rotate_to_version_two(configuration)
      assert {:ok, %{rekeyed: 1}} = Accounts.rekey_bank_data()

      # Simulate a buggy installer run that resets the keyring config back to the
      # original single-key state without preserving the rotation to version 2.
      Application.put_env(:fahrgastrechte, BankDataCipher, configuration)

      assert {:error, [:crypto]} = Health.ready()
    end
  end
end
