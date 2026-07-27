defmodule Fahrgastrechte.Accounts.Profile do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fahrgastrechte.Accounts.User

  @salutations ~w(female male neutral)
  @required_fields ~w(
    salutation
    first_name
    last_name
    street
    house_number
    postal_code
    city
    country
    account_holder
    iban
    bic
  )a

  @type t :: %__MODULE__{}

  schema "traveller_profiles" do
    field :salutation, :string
    field :title, :string
    field :first_name, :string
    field :last_name, :string
    field :street, :string
    field :house_number, :string
    field :postal_code, :string
    field :city, :string
    field :country, :string
    field :phone_number, :string
    field :account_holder, :string
    field :iban_ciphertext, :binary, redact: true
    field :bic_ciphertext, :binary, redact: true
    field :bank_data_key_version, :integer, redact: true
    field :iban, :string, virtual: true, redact: true
    field :bic, :string, virtual: true, redact: true

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :salutation,
      :title,
      :first_name,
      :last_name,
      :street,
      :house_number,
      :postal_code,
      :city,
      :country,
      :phone_number,
      :account_holder,
      :iban,
      :bic
    ])
    |> normalize_fields()
    |> validate_inclusion(:salutation, @salutations)
    |> validate_length(:title, max: 40)
    |> validate_length(:first_name, max: 100)
    |> validate_length(:last_name, max: 100)
    |> validate_length(:street, max: 150)
    |> validate_length(:house_number, max: 20)
    |> validate_format(:postal_code, ~r/^[[:alnum:]][[:alnum:] -]{1,11}$/u)
    |> validate_length(:city, max: 100)
    |> validate_length(:country, min: 2, max: 100)
    |> validate_length(:phone_number, max: 40)
    |> validate_length(:account_holder, max: 200)
    |> validate_change(:iban, &validate_iban/2)
    |> validate_format(:bic, ~r/^[A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?$/,
      message: "muss aus 8 oder 11 gültigen Zeichen bestehen"
    )
  end

  def required_fields, do: @required_fields

  defp normalize_fields(changeset) do
    Enum.reduce(
      [
        :salutation,
        :title,
        :first_name,
        :last_name,
        :street,
        :house_number,
        :postal_code,
        :city,
        :country,
        :phone_number,
        :account_holder
      ],
      changeset,
      &update_change(&2, &1, fn value -> trim_optional(value) end)
    )
    |> update_change(:iban, &normalize_bank_value/1)
    |> update_change(:bic, &normalize_bank_value/1)
  end

  defp trim_optional(nil), do: nil
  defp trim_optional(value), do: String.trim(value)

  defp normalize_bank_value(nil), do: nil

  defp normalize_bank_value(value) do
    value
    |> String.replace(~r/\s+/u, "")
    |> String.upcase()
  end

  defp validate_iban(:iban, iban) do
    cond do
      not Regex.match?(~r/^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$/, iban) ->
        [iban: "hat kein gültiges Format"]

      iban_remainder(iban) != 1 ->
        [iban: "enthält eine ungültige Prüfsumme"]

      true ->
        []
    end
  end

  defp iban_remainder(iban) do
    <<country::binary-size(2), checksum::binary-size(2), rest::binary>> = iban

    (rest <> country <> checksum)
    |> String.to_charlist()
    |> Enum.reduce(0, fn
      character, remainder when character in ?0..?9 ->
        rem(remainder * 10 + character - ?0, 97)

      character, remainder when character in ?A..?Z ->
        value = character - ?A + 10
        rem(remainder * 100 + value, 97)
    end)
  end
end
