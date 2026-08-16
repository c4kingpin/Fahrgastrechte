defmodule Fahrgastrechte.Accounts.BankDataCipher do
  @moduledoc false

  @aad_prefix "fahrgastrechte:accounts:bank-data"
  @nonce_bytes 12
  @tag_bytes 16

  @spec encrypt(String.t(), atom(), pos_integer()) ::
          {:ok, binary(), pos_integer()} | {:error, :encryption_key_unavailable}
  def encrypt(value, field, user_id)
      when is_binary(value) and field in [:iban, :bic] and is_integer(user_id) do
    with {:ok, version, key} <- active_key() do
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)
      aad = aad(version, field, user_id)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, value, aad, true)

      {:ok, nonce <> tag <> ciphertext, version}
    end
  end

  @spec decrypt(binary(), pos_integer(), atom(), pos_integer()) ::
          {:ok, String.t()} | {:error, :invalid_ciphertext | :encryption_key_unavailable}
  def decrypt(
        <<nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>,
        version,
        field,
        user_id
      )
      when is_integer(version) and version > 0 and field in [:iban, :bic] and
             is_integer(user_id) do
    with {:ok, key} <- key(version) do
      # Records written before the additional data was bound to the owning user
      # carry the legacy prefix. `mix fahrgastrechte.rekey_bank_data` (or
      # `Fahrgastrechte.Release.rekey_bank_data/0`) rewrites them; the fallback
      # can be removed once every installation has run it.
      candidate_aads = [aad(version, field, user_id), legacy_aad(version, field)]

      Enum.reduce_while(candidate_aads, {:error, :invalid_ciphertext}, fn aad, error ->
        case :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               key,
               nonce,
               ciphertext,
               aad,
               tag,
               false
             ) do
          plaintext when is_binary(plaintext) -> {:halt, {:ok, plaintext}}
          _error -> {:cont, error}
        end
      end)
    end
  end

  def decrypt(_ciphertext, _version, _field, _user_id), do: {:error, :invalid_ciphertext}

  @doc "Returns the key version new ciphertext is written with."
  @spec active_key_version() :: {:ok, pos_integer()} | {:error, :encryption_key_unavailable}
  def active_key_version do
    with {:ok, version, _key} <- active_key(), do: {:ok, version}
  end

  defp active_key do
    config = config()
    version = Keyword.get(config, :active_key_version)

    with true <- is_integer(version) and version > 0,
         {:ok, key} <- key(version) do
      {:ok, version, key}
    else
      _other -> {:error, :encryption_key_unavailable}
    end
  end

  defp key(version) do
    case config() |> Keyword.get(:keys, %{}) |> Map.get(version) do
      key when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
      _other -> {:error, :encryption_key_unavailable}
    end
  end

  defp config do
    Application.get_env(:fahrgastrechte, __MODULE__, [])
  end

  defp aad(version, field, user_id),
    do: "#{@aad_prefix}:v#{version}:#{field}:u#{user_id}"

  defp legacy_aad(version, field), do: "#{@aad_prefix}:v#{version}:#{field}"
end
