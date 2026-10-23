defmodule FahrgastrechteWeb.Features.ProfileTest do
  use FahrgastrechteWeb.FeatureCase

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.Scope

  test "fills in and saves the complete traveller profile", %{conn: conn} do
    user = user_fixture()

    conn
    |> log_in(user)
    |> visit(~p"/profil")
    |> assert_connected()
    |> assert_has("#profile-completeness", text: "Noch unvollständig")
    |> select("Anrede *", option: "Frau", exact: false)
    |> fill_in("Titel", with: "Dr.")
    |> fill_in("Vorname *", with: "Erika")
    |> fill_in("Nachname *", with: "Beispiel")
    |> fill_in("Straße *", with: "Testweg")
    |> fill_in("Hausnummer *", with: "1a")
    |> fill_in("Postleitzahl *", with: "10115")
    |> fill_in("Ort *", with: "Berlin")
    |> fill_in("Staat *", with: "Deutschland")
    |> fill_in("Telefonnummer", with: "+49 30 1234567")
    |> fill_in("Kontoinhaber *", with: "Erika Beispiel")
    |> fill_in("IBAN *", with: "de89 3704 0044 0532 0130 00")
    |> fill_in("BIC *", with: "COBADEFFXXX")
    |> click_button("#profile-save", "Profil speichern")
    |> assert_has("#flash-info", text: "Dein Reisendenprofil wurde sicher gespeichert.")
    |> assert_has("#profile-completeness", text: "Vollständig")

    assert {:ok, profile} = Accounts.get_profile(Scope.for_user(user))
    assert profile.salutation == "female"
    assert profile.title == "Dr."
    assert profile.iban == "DE89370400440532013000"
    assert Accounts.profile_complete?(profile)

    conn
    |> reload_page()
    |> assert_has("#profile-first-name[value='Erika']")
    |> assert_has("#profile-iban[value='DE89370400440532013000']")
  end

  test "reports invalid bank data and postal code while typing and refuses to save", %{
    conn: conn
  } do
    scope = scope_fixture()

    conn
    |> log_in(scope)
    |> visit(~p"/profil")
    |> assert_connected()
    |> fill_in("IBAN *", with: "DE00")
    |> assert_has("#profile-iban-errors", text: "hat kein gültiges Format")
    |> fill_in("IBAN *", with: "DE89370400440532013001")
    |> assert_has("#profile-iban-errors", text: "enthält eine ungültige Prüfsumme")
    |> fill_in("BIC *", with: "123")
    |> assert_has("#profile-bic-errors", text: "muss aus 8 oder 11 gültigen Zeichen bestehen")
    |> fill_in("Postleitzahl *", with: "!")
    |> assert_has("#profile-postal-code-errors")
    |> click_button("#profile-save", "Profil speichern")
    |> refute_has("#flash-info")
    |> assert_has("#profile-iban[aria-invalid=true]")

    assert {:ok, profile} = Accounts.get_profile(scope)
    assert is_nil(profile.iban)
  end

  test "returns to the claim after saving when opened from a claim", %{conn: conn} do
    scope = scope_fixture()
    claim = claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/profil?antrag=#{claim.id}")
    |> assert_connected()
    |> assert_has("#profile-back-to-claim", text: "Zurück zum Antrag")
    |> select("Anrede *", option: "Neutrale Anrede", exact: false)
    |> fill_in("Vorname *", with: "Erika")
    |> click_button("#profile-save", "Speichern und zum Antrag")
    |> assert_path(~p"/antraege/#{claim.id}")
    |> assert_has("#claim-workspace")
  end

  test "the back link leads to the claim without saving", %{conn: conn} do
    scope = scope_fixture()
    claim = claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/profil?antrag=#{claim.id}")
    |> click_link("#profile-back-to-claim", "Zurück zum Antrag")
    |> assert_path(~p"/antraege/#{claim.id}")
  end

  test "ignores an invalid claim reference", %{conn: conn} do
    conn
    |> log_in(user_fixture())
    |> visit(~p"/profil?antrag=kein-antrag")
    |> refute_has("#profile-back-to-claim")
    |> assert_has("#profile-save", text: "Profil speichern")
  end
end
