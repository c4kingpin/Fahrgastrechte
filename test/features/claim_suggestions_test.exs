defmodule FahrgastrechteWeb.Features.ClaimSuggestionsTest do
  use FahrgastrechteWeb.FeatureCase

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Tickets

  setup do
    scope = scope_fixture()
    %{scope: scope}
  end

  test "confirms every recognised fact at once from the trip summary", %{conn: conn, scope: scope} do
    claim = analyzed_claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_connected()
    |> assert_has("#trip-summary-route", text: "Teststadt Hbf → Beispielstadt Hbf (Vorschlag)")
    |> assert_has("#trip-summary-order-number", text: "000000000001")
    |> refute_has("#order-number-mismatch-warning")
    |> click_button("#confirm-all-facts", "Ja, diese Angaben stimmen")
    |> refute_has("#confirm-all-facts")
    # With every recognised fact settled, the assistant moves on by itself.
    |> refute_path(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_has("#claim-step-vorschlaege[data-state=confirmed]")
    |> assert_has("#trip-summary-route", text: "Teststadt Hbf → Beispielstadt Hbf")
    |> refute_has("#trip-summary-route", text: "(Vorschlag)")
    |> click_link("#claim-step-vorschlaege", "Angaben prüfen")
    |> assert_has("#accept-all-suggestions[disabled]")
    |> assert_has("#reject-all-suggestions[disabled]")

    assert {:ok,
            %{
              origin: "Teststadt Hbf",
              destination: "Beispielstadt Hbf",
              travel_date: ~D[2026-04-15]
            }} =
             Claims.get_claim(scope, claim.id)
  end

  test "accepts and rejects single suggestions", %{conn: conn, scope: scope} do
    claim = analyzed_claim_fixture(scope)
    {:ok, suggestions} = Tickets.list_claim_suggestions(scope, claim.id)
    origin = Enum.find(suggestions, &(&1.field == :origin))
    destination = Enum.find(suggestions, &(&1.field == :destination))

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_connected()
    |> click_button("#accept-suggestion-#{origin.id}", "Übernehmen")
    |> assert_has("#flash-info",
      text: "Der Vorschlag wurde bestätigt und in die Falldaten übernommen."
    )
    |> refute_has("#accept-suggestion-#{origin.id}")
    |> click_button("#reject-suggestion-#{destination.id}", "Verwerfen")
    |> assert_has("#flash-info", text: "Der Vorschlag wurde verworfen.")
    |> refute_has("#reject-suggestion-#{destination.id}")
    |> assert_has("#route-suggestions article", text: "Bestätigt")
    |> assert_has("#route-suggestions article", text: "Verworfen")

    assert {:ok, %{origin: "Teststadt Hbf", destination: nil}} = Claims.get_claim(scope, claim.id)
  end

  test "an accepted travel date shows up in the journey form and survives its autosave", %{
    conn: conn,
    scope: scope
  } do
    claim = analyzed_claim_fixture(scope)
    {:ok, suggestions} = Tickets.list_claim_suggestions(scope, claim.id)
    travel_date = Enum.find(suggestions, &(&1.field == :travel_date))

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_connected()
    |> click_button("#accept-suggestion-#{travel_date.id}", "Übernehmen")
    |> assert_has("#flash-info", text: "in die Falldaten übernommen")
    |> click_link("#claim-step-falldaten", "Reiseverlauf")
    |> assert_has("#claim-travel-date", value: "15.04.2026")
    |> select("Fahrtrichtung", option: "Rückfahrt", exact: false)

    assert_eventually(fn ->
      {:ok, updated} = Claims.get_claim(scope, claim.id)
      updated.journey_direction == :return and updated.travel_date == ~D[2026-04-15]
    end)
  end

  test "rejects all open suggestions at once", %{conn: conn, scope: scope} do
    claim = analyzed_claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_connected()
    |> click_button("#reject-all-suggestions", "Alle verwerfen")
    |> assert_has("#flash-info", text: "Die erkannten Angaben wurden gemeinsam verworfen.")
    |> assert_has("#reject-all-suggestions[disabled]")
    |> refute_has("[id^=accept-suggestion-]")

    {:ok, suggestions} = Tickets.list_claim_suggestions(scope, claim.id)
    assert Enum.all?(suggestions, &(&1.state == :rejected))
  end

  test "accepts one topic group", %{conn: conn, scope: scope} do
    claim = analyzed_claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_connected()
    |> click_button("#accept-booking-suggestions", "Gruppe übernehmen")
    |> assert_has("#flash-info", text: "Die erkannten Angaben wurden gemeinsam übernommen.")
    |> refute_has("#booking-suggestions [id^=accept-suggestion-]")
    |> assert_has("#route-suggestions [id^=accept-suggestion-]")

    {:ok, suggestions} = Tickets.list_claim_suggestions(scope, claim.id)
    assert Enum.any?(suggestions, &(&1.field == :order_number and &1.state == :accepted))
    assert Enum.any?(suggestions, &(&1.field == :origin and &1.state == :proposed))
  end

  test "warns when ticket and invoice carry different order numbers", %{conn: conn, scope: scope} do
    claim = analyzed_claim_fixture(scope, "synthetic-ticket-flexpreis-business.pdf")

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_has("#order-number-mismatch-warning", text: "000000000002")
    |> assert_has("#order-number-mismatch-warning", text: "000000000001")
  end

  test "corrects recognised values manually with the station combobox", %{
    conn: conn,
    scope: scope
  } do
    station_fixture!("Leipzig Hbf", "8010205")
    station_fixture!("Leipzig Messe", "8012202")
    station_fixture!("Dresden Hbf", "8010085")
    claim = analyzed_claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_connected()
    |> within("#suggestion-correction-form", fn conn ->
      conn
      |> fill_in("Reisedatum", with: "16.04.2026")
      # Keyboard selection runs entirely in the .StationCombobox hook.
      |> fill_in("Startbahnhof", with: "Leip")
      |> assert_has("#correction-origin-option-1")
      |> press("#correction-origin", "ArrowDown")
      |> press("#correction-origin", "ArrowDown")
      |> assert_has("#correction-origin-option-1.is-active", text: "Leipzig Messe")
      |> assert_has("#correction-origin[aria-activedescendant=correction-origin-option-1]")
      |> press("#correction-origin", "ArrowUp")
      |> assert_has("#correction-origin-option-0.is-active", text: "Leipzig Hbf")
      |> press("#correction-origin", "ArrowDown")
      |> press("#correction-origin", "Enter")
      |> assert_has("#correction-origin", value: "Leipzig Messe")
      |> fill_in("Zielbahnhof", with: "Dres")
      |> click("#correction-destination-option-0")
      |> assert_has("#correction-destination", value: "Dresden Hbf")
      |> click_button("#save-suggestion-corrections", "Manuelle Angaben speichern")
    end)
    |> assert_has("#trip-summary-route", text: "Leipzig Messe → Dresden Hbf")

    assert {:ok,
            %{origin: "Leipzig Messe", destination: "Dresden Hbf", travel_date: ~D[2026-04-16]}} =
             Claims.get_claim(scope, claim.id)
  end

  test "Escape closes the station combobox without choosing", %{conn: conn, scope: scope} do
    station_fixture!("Leipzig Hbf", "8010205")
    claim = analyzed_claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_connected()
    |> fill_in("#correction-origin", "Startbahnhof", with: "Leip")
    |> assert_has("#correction-origin-option-0", text: "Leipzig Hbf")
    |> press("#correction-origin", "Escape")
    |> evaluate("document.activeElement.id", &refute(&1 == "correction-origin"))
    |> assert_has("#correction-origin", value: "Leip")
  end

  test "searches a different station for a recognised route value", %{conn: conn, scope: scope} do
    station_fixture!("Hannover Hbf", "8000152")
    claim = analyzed_claim_fixture(scope)
    {:ok, suggestions} = Tickets.list_claim_suggestions(scope, claim.id)
    origin = Enum.find(suggestions, &(&1.field == :origin))

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_connected()
    |> assert_has("#station-search-toggle-#{origin.id}[aria-expanded=true]")
    |> fill_selector("#station-search-form-#{origin.id} input", "Hann")
    |> assert_has("#station-option-#{origin.id}-0", text: "Hannover Hbf")
    |> click("#station-option-#{origin.id}-0")
    |> click_button("#accept-suggestion-#{origin.id}", "Übernehmen")
    |> assert_has("#flash-info", text: "in die Falldaten übernommen")

    assert {:ok, %{origin: "Hannover Hbf"}} = Claims.get_claim(scope, claim.id)
  end

  test "the station search can be collapsed, reopened and reports no matches", %{
    conn: conn,
    scope: scope
  } do
    claim = analyzed_claim_fixture(scope)
    {:ok, suggestions} = Tickets.list_claim_suggestions(scope, claim.id)
    origin = Enum.find(suggestions, &(&1.field == :origin))

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_connected()
    |> fill_selector("#station-search-form-#{origin.id} input", "Atlantis")
    |> assert_has("#station-search-panel-#{origin.id}", text: "Keine Bahnhöfe gefunden.")
    |> click_button("#station-search-toggle-#{origin.id}", "Anderen Bahnhof suchen")
    |> assert_has("#station-search-toggle-#{origin.id}[aria-expanded=false]")
    |> refute_has("#station-search-panel-#{origin.id}")
    |> click_button("#station-search-toggle-#{origin.id}", "Anderen Bahnhof suchen")
    |> assert_has("#station-search-form-#{origin.id} input", value: "Atlantis")
  end

  test "lets the person pick between conflicting values from ticket and invoice", %{
    conn: conn,
    scope: scope
  } do
    claim = claim_fixture(scope)
    {ticket, claim} = document_fixture(scope, claim, :ticket)
    {invoice, claim} = document_fixture(scope, claim, :invoice)
    ticket_fare = insert_fare_suggestion!(ticket, "19.90")
    invoice_fare = insert_fare_suggestion!(invoice, "21.40")

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_connected()
    |> assert_has("#booking-suggestions article", text: "2 unterschiedliche Werte gefunden")
    |> assert_has("#choose-suggestion-candidate-#{invoice_fare.id}", text: "21.40 EUR")
    |> click("#choose-suggestion-candidate-#{invoice_fare.id}")
    |> refute_has("#choose-suggestion-candidate-#{ticket_fare.id}")
    |> assert_has("#booking-suggestions article", text: "Bestätigt")

    {:ok, suggestions} = Tickets.list_claim_suggestions(scope, claim.id)
    assert Enum.find(suggestions, &(&1.id == invoice_fare.id)).state == :accepted
    assert Enum.find(suggestions, &(&1.id == ticket_fare.id)).state == :rejected
  end

  test "shows an empty state when a document has no readable text", %{conn: conn, scope: scope} do
    claim = claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/vorschlaege")
    |> assert_has("#suggestions-empty", text: "Noch keine Vorschläge")
    |> refute_has("#suggestion-bulk-actions")
  end

  defp insert_fare_suggestion!(document, amount) do
    %Fahrgastrechte.Tickets.Suggestion{document_id: document.id}
    |> Fahrgastrechte.Tickets.Suggestion.changeset(%{
      field: :fare,
      value: %{"amount" => amount, "currency" => "EUR"},
      confidence: 0.8,
      source_page: 1,
      source_excerpt: "Fahrpreis: #{amount} EUR",
      state: :proposed
    })
    |> Fahrgastrechte.Repo.insert!()
  end

  defp analyzed_claim_fixture(scope, ticket_fixture \\ "synthetic-ticket-flexpreis.pdf") do
    claim = claim_fixture(scope, %{"travel_date" => nil, "origin" => nil, "destination" => nil})

    {ticket, claim} =
      document_fixture(scope, claim, :ticket, %{path: fixture_path(ticket_fixture)})

    {invoice, claim} =
      document_fixture(scope, claim, :invoice, %{
        path: fixture_path("synthetic-invoice.pdf"),
        original_filename: "invoice.pdf"
      })

    for document <- [ticket, invoice] do
      {:ok, current} = Claims.get_claim(scope, claim.id)

      {:ok, _analysis} =
        Tickets.analyze_document(scope, claim.id, document.id, current.lock_version)
    end

    {:ok, claim} = Claims.get_claim(scope, claim.id)
    claim
  end
end
