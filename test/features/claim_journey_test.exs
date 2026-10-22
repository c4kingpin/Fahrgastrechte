defmodule FahrgastrechteWeb.Features.ClaimJourneyTest do
  use FahrgastrechteWeb.FeatureCase

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Rail

  setup do
    %{scope: scope_fixture()}
  end

  describe "planned journey" do
    test "looks up the connection with its live delay and adopts it", %{conn: conn, scope: scope} do
      station_fixture!("Teststadt Hbf", "9999999")
      station_fixture!("Beispielstadt Hbf", "9999998")

      claim =
        claim_fixture(scope, %{
          "travel_date" => ~D[2026-04-15],
          "origin" => "Teststadt Hbf",
          "destination" => "Beispielstadt Hbf"
        })

      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}/geplante-reise")
      |> assert_connected()
      |> assert_has("#connection-search-drawer[open]")
      |> within("#connection-search-form", fn conn ->
        conn
        |> fill_in("Geplante Abfahrt", with: "15.04.2026, 06:00")
        |> fill_in("Zugnummer (optional)", with: "100")
        |> click_button("#search-connections-button", "Verbindungen und Verspätungen abrufen")
      end)
      |> assert_has("#connection-search-status", text: "Verbindungen gefunden.")
      |> assert_has("#connection-delay-1[data-delay-minutes='32']", text: "+32 Min.")
      |> assert_has("#connection-results article", text: "ICE 100")
      |> assert_has("#connection-results article", text: "Direktverbindung")
      |> click_button("#choose-connection-1", "Verbindung übernehmen")
      |> assert_has("#claim-step-geplante-reise[data-state=confirmed]")
      |> click_link("#claim-step-tatsaechliche-reise", "Tatsächliche Reise")
      |> assert_has("#api-delay-summary", text: "derzeit 32 Minuten verspätet")
      |> assert_has("#actual-journey-timeline article", text: "Teststadt Hbf → Beispielstadt Hbf")

      assert {:ok, planned} = Rail.get_journey(scope, claim.id, :planned)
      assert hd(planned.segments).train_number == "100"
      assert {:ok, _actual} = Rail.get_journey(scope, claim.id, :actual)
    end

    test "reports a search without a usable departure time", %{conn: conn, scope: scope} do
      claim = claim_fixture(scope)

      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}/geplante-reise")
      |> assert_connected()
      |> within("#connection-search-form", fn conn ->
        conn
        |> fill_in("Geplante Abfahrt", with: "irgendwann")
        |> click_button("#search-connections-button", "Verbindungen und Verspätungen abrufen")
      end)
      |> assert_has("#connection-search-error",
        text: "Bitte gib eine gültige geplante Abfahrtszeit an."
      )
    end

    test "says so when no connection matches", %{conn: conn, scope: scope} do
      station_fixture!("Teststadt Hbf", "9999999")
      station_fixture!("Beispielstadt Hbf", "9999998")

      claim =
        claim_fixture(scope, %{
          "travel_date" => ~D[2026-04-15],
          "origin" => "Teststadt Hbf",
          "destination" => "Beispielstadt Hbf"
        })

      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}/geplante-reise")
      |> assert_connected()
      |> within("#connection-search-form", fn conn ->
        conn
        |> fill_in("Geplante Abfahrt", with: "15.04.2026, 06:00")
        |> fill_in("Zugnummer (optional)", with: "999")
        |> click_button("#search-connections-button", "Verbindungen und Verspätungen abrufen")
      end)
      |> assert_has("#connection-search-empty", text: "Keine eindeutige Verbindung gefunden.")
    end

    test "enters a connection with an interchange manually", %{conn: conn, scope: scope} do
      claim = claim_fixture(scope)

      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}/geplante-reise")
      |> assert_connected()
      |> within("#planned-journey-form", fn conn ->
        conn
        |> fill_in("Startbahnhof", with: "Berlin Hbf")
        |> fill_in("Zielbahnhof", with: "München Hbf")
        |> fill_in("Zuggattung", with: "ICE", exact: true)
        |> fill_in("Zugnummer", with: "700", exact: true)
        |> fill_in("Planmäßige Abfahrt", with: "15.07.2026, 06:00")
        |> fill_in("Planmäßige Ankunft", with: "15.07.2026, 11:30")
        |> click("#manual-transfer-editor summary")
        |> fill_in("Umstiegsbahnhof", with: "Nürnberg Hbf")
        |> fill_in("Ankunft am Umstieg", with: "15.07.2026, 09:00")
        |> fill_in("Weiterfahrt ab Umstieg", with: "15.07.2026, 09:20")
        |> fill_in("Zuggattung Weiterfahrt", with: "ICE")
        |> fill_in("Zugnummer Weiterfahrt", with: "525")
        |> click_button("#save-planned-journey", "Geplante Verbindung bestätigen")
      end)
      |> assert_has("#flash-info", text: "Die geplante Verbindung wurde bestätigt.")
      |> assert_has("#claim-step-geplante-reise[data-state=confirmed]")

      assert {:ok, journey} = Rail.get_journey(scope, claim.id, :planned)
      assert [first, second] = journey.segments
      assert first.destination_name == "Nürnberg Hbf"
      assert second.origin_name == "Nürnberg Hbf"
      assert second.train_number == "525"
    end

    test "rejects an incomplete manual connection", %{conn: conn, scope: scope} do
      claim = claim_fixture(scope)

      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}/geplante-reise")
      |> assert_connected()
      |> within("#planned-journey-form", fn conn ->
        conn
        |> fill_in("Startbahnhof", with: "Berlin Hbf")
        |> click_button("#save-planned-journey", "Geplante Verbindung bestätigen")
      end)
      |> assert_has("#flash-error")
      |> refute_has("#claim-step-geplante-reise[data-state=confirmed]")

      assert {:error, :not_found} = Rail.get_journey(scope, claim.id, :planned)
    end
  end

  test "a confirmed journey stays open for corrections while typing", %{conn: conn, scope: scope} do
    claim = claim_fixture(scope)
    journey_fixture(scope, claim, :planned)
    journey_fixture(scope, claim, :actual)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/geplante-reise")
    |> assert_connected()
    |> assert_has("#planned-journey-manual:not([open])")
    |> click("#planned-journey-manual > summary")
    |> within("#planned-journey-form", fn conn ->
      conn
      |> fill_in("Zugnummer", with: "101", exact: true)
      |> fill_in("Planmäßige Ankunft", with: "15.07.2026, 08:10")
      |> click_button("#save-planned-journey", "Geplante Verbindung bestätigen")
    end)
    |> assert_has("#flash-info", text: "Die geplante Verbindung wurde bestätigt.")
    |> visit(~p"/antraege/#{claim.id}/tatsaechliche-reise")
    |> assert_connected()
    |> click("#actual-journey-manual > summary")
    |> within("#actual-journey-form", fn conn ->
      conn
      |> fill_in("Tatsächliche Ankunft am Ziel", with: "15.07.2026, 09:45")
      |> fill_in("Zugnummer", with: "101", exact: true)
      |> click_button("#save-actual-journey", "Tatsächliche Reise bestätigen")
    end)
    |> assert_has("#flash-info", text: "Der tatsächliche Reiseverlauf wurde bestätigt.")

    assert {:ok, planned} = Rail.get_journey(scope, claim.id, :planned)
    assert [%{train_number: "101"} = segment] = planned.segments
    assert DateTime.compare(segment.scheduled_arrival, ~U[2026-07-15 06:10:00Z]) == :eq
    assert {:ok, actual} = Rail.get_journey(scope, claim.id, :actual)
    assert [%{train_number: "101"} = segment] = actual.segments
    assert DateTime.compare(segment.actual_arrival, ~U[2026-07-15 07:45:00Z]) == :eq
  end

  describe "actual journey" do
    setup %{scope: scope} do
      claim = claim_fixture(scope)
      journey_fixture(scope, claim, :planned)
      {:ok, claim} = Claims.get_claim(scope, claim.id)
      %{claim: claim}
    end

    test "confirms a delayed arrival", %{conn: conn, scope: scope, claim: claim} do
      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}/tatsaechliche-reise")
      |> assert_connected()
      |> assert_has("#choose-delay[aria-pressed=true]")
      |> assert_has("#actual-journey-timeline-empty")
      |> within("#actual-journey-form", fn conn ->
        conn
        |> fill_in("Startbahnhof", with: "Berlin Hbf")
        |> fill_in("Zielbahnhof", with: "Hamburg Hbf")
        |> fill_in("Zuggattung", with: "ICE", exact: true)
        |> fill_in("Zugnummer", with: "100", exact: true)
        |> fill_in("Planmäßige Abfahrt", with: "15.07.2026, 06:00")
        |> fill_in("Planmäßige Ankunft", with: "15.07.2026, 08:00")
        |> fill_in("Tatsächliche/Prognose-Abfahrt", with: "15.07.2026, 06:20")
        |> fill_in("Tatsächliche Ankunft am Ziel", with: "15.07.2026, 09:15")
        |> click_button("#save-actual-journey", "Tatsächliche Reise bestätigen")
      end)
      |> assert_has("#flash-info", text: "Der tatsächliche Reiseverlauf wurde bestätigt.")
      |> assert_has("#claim-step-tatsaechliche-reise[data-state=confirmed]")
      |> visit(~p"/antraege/#{claim.id}/tatsaechliche-reise")
      |> assert_has("#actual-journey-timeline article", text: "Berlin Hbf → Hamburg Hbf")
      |> assert_has("#actual-journey-manual:not([open])")

      assert {:ok, values} = Rail.form_values(scope, claim.id)
      assert DateTime.compare(values.actual_destination_arrival, ~U[2026-07-15 07:15:00Z]) == :eq
    end

    test "records a cancellation with its replacement train", %{
      conn: conn,
      scope: scope,
      claim: claim
    } do
      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}/tatsaechliche-reise")
      |> assert_connected()
      |> refute_has("#replacement-connection-fields")
      |> click_button("#choose-cancellation", "Zugausfall")
      |> assert_has("#choose-cancellation[aria-pressed=true]")
      |> assert_has("#choose-delay[aria-pressed=false]")
      |> within("#actual-journey-form", fn conn ->
        conn
        |> fill_in("Startbahnhof", with: "Berlin Hbf")
        |> fill_in("Zielbahnhof", with: "Hamburg Hbf")
        |> fill_in("Zuggattung", with: "ICE", exact: true)
        |> fill_in("Zugnummer", with: "100", exact: true)
        |> fill_in("Planmäßige Abfahrt", with: "15.07.2026, 06:00")
        |> fill_in("Planmäßige Ankunft", with: "15.07.2026, 08:00")
        |> fill_in("Zuggattung Ersatz", with: "IC")
        |> fill_in("Zugnummer Ersatz", with: "2000")
        |> fill_in("Abfahrt Ersatz", with: "15.07.2026, 07:00")
        |> fill_in("Ankunft Ersatz", with: "15.07.2026, 09:30")
        |> click_button("#save-actual-journey", "Tatsächliche Reise bestätigen")
      end)
      |> assert_has("#flash-info", text: "Der tatsächliche Reiseverlauf wurde bestätigt.")

      assert {:ok, %{disruption_cause: :cancellation}} = Claims.get_claim(scope, claim.id)
      assert {:ok, actual} = Rail.get_journey(scope, claim.id, :actual)
      assert Enum.any?(actual.segments, & &1.cancelled)
      assert Enum.any?(actual.segments, &(&1.train_number == "2000"))
    end

    test "records a missed connection with the onward train", %{
      conn: conn,
      scope: scope,
      claim: claim
    } do
      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}/tatsaechliche-reise")
      |> assert_connected()
      |> click_button("#choose-missed-connection", "Anschluss verpasst")
      |> assert_has("#missed-connection-fields")
      |> within("#actual-journey-form", fn conn ->
        conn
        |> fill_in("Startbahnhof", with: "Berlin Hbf")
        |> fill_in("Zielbahnhof", with: "Hannover Hbf")
        |> fill_in("Zuggattung", with: "ICE", exact: true)
        |> fill_in("Zugnummer", with: "100", exact: true)
        |> fill_in("Planmäßige Abfahrt", with: "15.07.2026, 06:00")
        |> fill_in("Planmäßige Ankunft", with: "15.07.2026, 07:00")
        |> fill_in("Tatsächliche/Prognose-Abfahrt", with: "15.07.2026, 06:10")
        |> fill_in("Tatsächliche Ankunft am Ziel", with: "15.07.2026, 07:20")
        |> fill_in("Zuggattung Anschluss", with: "IC")
        |> fill_in("Zugnummer Anschluss", with: "200")
        |> fill_in("Abfahrt Anschluss", with: "15.07.2026, 08:00")
        |> fill_in("Ankunft Anschluss", with: "15.07.2026, 09:00")
        |> click_button("#save-actual-journey", "Tatsächliche Reise bestätigen")
      end)
      |> assert_has("#flash-info", text: "Der tatsächliche Reiseverlauf wurde bestätigt.")
      |> visit(~p"/antraege/#{claim.id}/tatsaechliche-reise")
      |> assert_has("#actual-journey-timeline article", text: "Hannover Hbf")

      assert {:ok, actual} = Rail.get_journey(scope, claim.id, :actual)
      assert [feeder, onward] = actual.segments
      assert feeder.train_number == "100"
      assert onward.train_number == "200"
    end
  end
end
