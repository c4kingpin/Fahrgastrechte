defmodule Fahrgastrechte.AccountsFixtures do
  @moduledoc false

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.Identity
  alias Fahrgastrechte.Accounts.Scope

  def identity_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      issuer: "https://identity.example.invalid/application/fahrgastrechte",
      subject: "subject-#{unique}",
      email: "person-#{unique}@example.invalid",
      display_name: "Testperson #{unique}"
    }

    struct!(Identity, Map.merge(defaults, attrs))
  end

  def user_fixture(attrs \\ %{}) do
    {:ok, user} = attrs |> identity_fixture() |> Accounts.register_identity()
    user
  end

  def scope_fixture(attrs \\ %{}) do
    attrs
    |> user_fixture()
    |> Scope.for_user()
  end

  def valid_profile_attributes(attrs \\ %{}) do
    Map.merge(
      %{
        "salutation" => "neutral",
        "title" => "",
        "first_name" => "Erika",
        "last_name" => "Beispiel",
        "street" => "Testweg",
        "house_number" => "1",
        "postal_code" => "10115",
        "city" => "Berlin",
        "country" => "Deutschland",
        "phone_number" => "",
        "account_holder" => "Erika Beispiel",
        "iban" => "DE89370400440532013000",
        "bic" => "COBADEFFXXX"
      },
      attrs
    )
  end
end
