defmodule Fahrgastrechte.Accounts.BankDataCipher do
  @moduledoc false

  @aad_prefix "fahrgastrechte:accounts:bank-data"
  @nonce_bytes 12
  @tag_bytes 16

  @spec encrypt(String.t(), atom()) ::
          {:ok, binary(), pos_integer()} | {:error, :encryption_key_unavailable}
  def encrypt(value, field) when is_binary(value) and field in [:iban, :bic] do
    with {:ok, version, key} <- active_key() do
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)
      aad = aad(version, field)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, value, aad, true)

      {:ok, nonce <> tag <> ciphertext, version}
    end
  end

  @spec decrypt(binary(), pos_integer(), atom()) ::
          {:ok, String.t()} | {:error, :invalid_ciphertext | :encryption_key_unavailable}
  def decrypt(
        <<nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>,
        version,
        field
      )
      when is_integer(version) and version > 0 and field in [:iban, :bic] do
    with {:ok, key} <- key(version),
         plaintext
         when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             aad(version, field),
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      :error -> {:error, :invalid_ciphertext}
      {:error, _reason} = error -> error
    end
  end

  def decrypt(_ciphertext, _version, _field), do: {:error, :invalid_ciphertext}

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

  defp aad(version, field), do: "#{@aad_prefix}:v#{version}:#{field}"
end
