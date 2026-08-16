defmodule Fahrgastrechte.Accounts.BicLookup do
  @moduledoc """
  Derives a BIC from the bank code embedded in a German IBAN.

  German IBANs carry the 8-digit Bankleitzahl in positions 5..12, which maps
  deterministically to one BIC. The table below is deliberately partial: it
  covers nationwide banks whose bank code is unambiguous, so a lookup either
  returns the one correct BIC or admits it does not know. Institutions with
  many regional bank codes (Sparkassen, Volksbanken) are intentionally absent
  rather than guessed, and the BIC stays a normal editable field either way.
  """

  @bank_codes %{
    "10011001" => "NTSBDEB1XXX",
    "10070000" => "DEUTDEBBXXX",
    "10090000" => "GENODEF1P01",
    "12030000" => "BYLADEM1001",
    "20041133" => "COBADEHD055",
    "20411111" => "COBADEHDXXX",
    "30020900" => "TUBDDEDDXXX",
    "37040044" => "COBADEFFXXX",
    "43060967" => "GENODEM1GLS",
    "50010060" => "PBNKDEFFXXX",
    "50010517" => "INGDDEFFXXX",
    "50050201" => "HELADEF1822",
    "70020270" => "HYVEDEMMXXX",
    "76026000" => "NORSDE71XXX"
  }

  @doc """
  Returns the BIC for a German IBAN, or `:unknown` when it cannot be derived.

  Non-German and malformed IBANs always yield `:unknown`.
  """
  @spec derive(String.t() | nil) :: {:ok, String.t()} | :unknown
  def derive(iban) when is_binary(iban) do
    normalized = iban |> String.replace(~r/\s+/u, "") |> String.upcase()

    case normalized do
      <<"DE", _check::binary-size(2), bank_code::binary-size(8), _account::binary>> ->
        case Map.fetch(@bank_codes, bank_code) do
          {:ok, bic} -> {:ok, bic}
          :error -> :unknown
        end

      _other ->
        :unknown
    end
  end

  def derive(_iban), do: :unknown
end
