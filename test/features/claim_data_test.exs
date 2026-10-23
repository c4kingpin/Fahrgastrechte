defmodule FahrgastrechteWeb.Features.ClaimDataTest do
  use FahrgastrechteWeb.FeatureCase

  alias Fahrgastrechte.Claims

  setup do
    scope = scope_fixture()
    %{scope: scope, claim: claim_fixture(scope)}
  end

  test "autosaves every field of the journey outcome", %{conn: conn, scope: scope, claim: claim} do
    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/falldaten")
    |> assert_connected()
    |> assert_has("#claim-save-state[data-state=saved]", text: "Erfolgreich gespeichert")
    |> fill_in("Reisedatum", with: "02.08.2026")
    |> select("Reiseverlauf", option: "Reise abgebrochen", exact: false)
    |> select("Ursache", option: "Zugausfall", exact: false)
    |> select("Fahrtrichtung", option: "Rückfahrt", exact: false)
    |> fill_in("Startbahnhof", with: "Köln Hbf")
    |> fill_in("Zielbahnhof", with: "Bonn Hbf")
    |> assert_has("#claim-save-state[data-state=saved]")

    assert_eventually(fn ->
      {:ok, updated} = Claims.get_claim(scope, claim.id)

      updated.travel_date == ~D[2026-08-02] and updated.journey_outcome == :aborted and
        updated.disruption_cause == :cancellation and updated.journey_direction == :return and
        updated.origin == "Köln Hbf" and updated.destination == "Bonn Hbf"
    end)

    conn
    |> reload_page()
    |> assert_has("#claim-travel-date", value: "02.08.2026")
    |> assert_has("#claim-origin", value: "Köln Hbf")
  end

  test "the native date picker fills the German date field", %{
    conn: conn,
    scope: scope,
    claim: claim
  } do
    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/falldaten")
    |> assert_connected()
    |> assert_has("#claim-travel-date[placeholder='TT.MM.JJJJ']", value: "15.07.2026")
    |> fill_selector("#claim-travel-date-picker [data-role=native-picker]", "2026-08-03")
    |> evaluate(
      ~s|document.querySelector("#claim-travel-date-picker [data-role=native-picker]").dispatchEvent(new Event("change"))|
    )
    |> assert_has("#claim-travel-date", value: "03.08.2026")

    assert_eventually(fn ->
      {:ok, updated} = Claims.get_claim(scope, claim.id)
      updated.travel_date == ~D[2026-08-03]
    end)
  end

  test "typing a German date keeps the native picker in sync", %{
    conn: conn,
    scope: scope,
    claim: claim
  } do
    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/falldaten")
    |> assert_connected()
    |> fill_in("Reisedatum", with: "24.12.2026")
    |> press("#claim-travel-date", "Tab")
    |> assert_has("#claim-travel-date-picker [data-role=native-picker]", value: "2026-12-24")
  end

  test "flags an invalid value without saving it", %{conn: conn, scope: scope, claim: claim} do
    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/falldaten")
    |> assert_connected()
    |> fill_in("Startbahnhof", with: String.duplicate("B", 201))
    |> assert_has("#claim-save-state[data-state=invalid]", text: "Eingabe prüfen")

    assert {:ok, %{origin: "Berlin Hbf"}} = Claims.get_claim(scope, claim.id)
  end

  test "reloads the claim when it was changed elsewhere in the meantime", %{
    conn: conn,
    scope: scope,
    claim: claim
  } do
    conn =
      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}/falldaten")
      |> assert_connected()

    {:ok, _external} =
      Claims.update_claim(
        scope,
        claim.id,
        %{"origin" => "Extern gespeichert"},
        claim.lock_version
      )

    conn
    |> fill_in("Zielbahnhof", with: "Eigene Änderung")
    |> assert_has("#claim-save-state[data-state=conflict]", text: "Konflikt erkannt")
    |> assert_has("#flash-error", text: "Der Antrag wurde zwischenzeitlich geändert.")
    |> assert_has("#claim-origin", value: "Extern gespeichert")

    assert {:ok, %{origin: "Extern gespeichert", destination: "Hamburg Hbf"}} =
             Claims.get_claim(scope, claim.id)
  end

  test "keeps a station chosen with the keyboard when another field changes", %{
    conn: conn,
    scope: scope,
    claim: claim
  } do
    station_fixture!("Leipzig Hbf", "8010205")

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/falldaten")
    |> assert_connected()
    |> fill_in("Startbahnhof", with: "Leip")
    |> assert_has("#claim-origin-option-0", text: "Leipzig Hbf")
    |> press("#claim-origin", "ArrowDown")
    |> press("#claim-origin", "Enter")
    |> assert_has("#claim-origin", value: "Leipzig Hbf")
    |> select("Fahrtrichtung", option: "Rückfahrt", exact: false)

    assert_eventually(fn ->
      {:ok, updated} = Claims.get_claim(scope, claim.id)
      updated.journey_direction == :return and updated.origin == "Leipzig Hbf"
    end)
  end

  test "a station picked with the mouse is saved right away", %{
    conn: conn,
    scope: scope,
    claim: claim
  } do
    station_fixture!("Dresden Hbf", "8010085")

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/falldaten")
    |> assert_connected()
    |> fill_in("Zielbahnhof", with: "Dres")
    |> click("#claim-destination-option-0")
    |> assert_has("#claim-destination", value: "Dresden Hbf")

    assert_eventually(fn ->
      {:ok, updated} = Claims.get_claim(scope, claim.id)
      updated.destination == "Dresden Hbf"
    end)
  end
end
