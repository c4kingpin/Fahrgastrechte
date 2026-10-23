defmodule FahrgastrechteWeb.Features.ClaimAssistantTest do
  use FahrgastrechteWeb.FeatureCase

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Exports
  alias Fahrgastrechte.Rail

  @steps [
    {"dokumente", "Ticket & Rechnung", "claim-documents-heading"},
    {"vorschlaege", "Angaben prüfen", "ticket-suggestions-heading"},
    {"falldaten", "Reiseverlauf", "claim-data-heading"},
    {"geplante-reise", "Geplante Reise", "planned-journey-heading"},
    {"tatsaechliche-reise", "Tatsächliche Reise", "actual-journey-heading"},
    {"pruefung", "Prüfung & PDF", "claim-review-heading"}
  ]

  setup do
    on_exit(fn -> File.rm_rf(storage_path()) end)
    %{scope: scope_fixture()}
  end

  test "walks a new claim from the PDFs to the print-ready application", %{
    conn: conn,
    scope: scope
  } do
    station_fixture!("Teststadt Hbf", "9999999")
    station_fixture!("Beispielstadt Hbf", "9999998")
    {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())

    conn
    |> log_in(scope)
    |> visit(~p"/antraege")
    |> assert_connected()
    |> click_button("#new-claim-button", "Neuen Antrag beginnen")
    |> assert_has("#claim-documents-section")
    |> upload_files("PDFs hierher ziehen oder auswählen", [
      fixture_path(),
      fixture_path("synthetic-invoice.pdf")
    ])
    |> assert_has("#analysis-status-ticket", text: "Auswertung abgeschlossen")
    |> assert_has("#analysis-status-invoice", text: "Auswertung abgeschlossen")
    |> click_link("#claim-step-vorschlaege", "Angaben prüfen")
    |> assert_has("#trip-summary-route", text: "Teststadt Hbf → Beispielstadt Hbf (Vorschlag)")
    |> click_button("#confirm-all-facts", "Ja, diese Angaben stimmen")
    # The only matching connection is looked up and adopted on its own; the
    # assistant then asks for the one thing no PDF contains: what went wrong.
    |> assert_has("#flash-info",
      text: "Wir haben die passende Verbindung samt aktueller Verspätung automatisch übernommen."
    )
    |> assert_path(~p"/antraege/#{claim_id(scope)}/falldaten")
    |> assert_has("#workspace-progress-label",
      text: "es fehlt noch: Angaben zu deiner Reise vervollständigen"
    )
    |> assert_has("#claim-origin", value: "Teststadt Hbf")
    |> assert_has("#claim-travel-date", value: "15.04.2026")
    |> select("Reiseverlauf", option: "Verspätet am Ziel angekommen", exact: false)
    |> select("Ursache", option: "Verspätung", exact: false)
    |> assert_has("#claim-step-falldaten[data-state=confirmed]")
    |> click_link("#claim-step-pruefung", "Prüfung & PDF")
    |> assert_has("#claim-step-geplante-reise[data-state=confirmed]")
    |> assert_has("#claim-step-tatsaechliche-reise[data-state=confirmed]")
    |> assert_has("#workspace-progress-label", text: "Bereit zur Prüfung")
    |> click_button("#generate-export-button", "Druckfertiges PDF erstellen")
    |> assert_has("#claim-status", text: "Druckfertig")
    |> assert_has("#claim-exports article", text: "Aktuell · bereit zum Versand")

    assert {:ok, [claim]} = Claims.list_claims(scope)
    assert {:ok, planned} = Rail.get_journey(scope, claim.id, :planned)
    assert hd(planned.segments).train_number == "100"
    assert {:ok, [_export]} = Exports.list_exports(scope, claim.id)
  end

  test "the stepper opens every step, marks it and moves the focus to its heading", %{
    conn: conn,
    scope: scope
  } do
    claim = claim_fixture(scope)

    conn =
      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}/dokumente")
      |> assert_connected()

    for {slug, label, heading_id} <- tl(@steps) do
      conn
      |> click_link("#claim-step-#{slug}", label)
      |> assert_path(~p"/antraege/#{claim.id}/#{slug}")
      |> assert_has("#claim-step-#{slug}[aria-current=step]")
      |> assert_has("##{heading_id}")
      |> assert_focused(heading_id)
    end
  end

  test "browser back and forward follow the visited steps", %{conn: conn, scope: scope} do
    claim = claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/dokumente")
    |> assert_connected()
    |> click_link("#claim-step-falldaten", "Reiseverlauf")
    |> assert_path(~p"/antraege/#{claim.id}/falldaten")
    |> click_link("#claim-step-pruefung", "Prüfung & PDF")
    |> assert_path(~p"/antraege/#{claim.id}/pruefung")
    |> evaluate("history.back()")
    |> assert_path(~p"/antraege/#{claim.id}/falldaten")
    |> assert_has("#claim-data-section:not([hidden])")
    |> evaluate("history.forward()")
    |> assert_path(~p"/antraege/#{claim.id}/pruefung")
    |> assert_has("#claim-review-export-section:not([hidden])")
  end

  test "resumes at the first open step and corrects an unknown step address", %{
    conn: conn,
    scope: scope
  } do
    claim = claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}")
    |> assert_has("#claim-documents-section:not([hidden])")
    |> assert_has("#workspace-progress-label",
      text: "Es fehlt noch: Ticket und Rechnung hochladen"
    )
    |> visit(~p"/antraege/#{claim.id}/gibt-es-nicht")
    |> assert_path(~p"/antraege/#{claim.id}/dokumente")
    |> assert_has("#claim-documents-section:not([hidden])")
  end

  @tag browser_context_opts: [
         viewport: %{width: 390, height: 844},
         locale: "de-DE",
         timezone_id: "Europe/Berlin"
       ]
  test "on a phone the bottom bar steps forwards and backwards", %{conn: conn, scope: scope} do
    claim = claim_fixture(scope)

    conn =
      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}/dokumente")
      |> assert_connected()
      |> assert_has("#claim-step-mobile-navigation", text: "1 / 6")
      |> assert_has("#claim-step-back", text: "Anträge")

    conn =
      Enum.reduce(Enum.with_index(tl(@steps), 2), conn, fn {{slug, _label, heading_id}, number},
                                                           conn ->
        conn
        |> click_link("#claim-step-forward", "Weiter")
        |> assert_path(~p"/antraege/#{claim.id}/#{slug}")
        |> assert_has("#claim-step-mobile-navigation", text: "#{number} / 6")
        |> assert_focused(heading_id)
      end)

    conn
    |> assert_has("#claim-step-forward[aria-disabled=true]", text: "Fertig")
    |> click_link("#claim-step-back", "Zurück")
    |> assert_path(~p"/antraege/#{claim.id}/tatsaechliche-reise")
    |> visit(~p"/antraege/#{claim.id}/dokumente")
    |> click_link("#claim-step-back", "Anträge")
    |> assert_path(~p"/antraege")
  end

  defp claim_id(scope) do
    {:ok, [claim]} = Claims.list_claims(scope)
    claim.id
  end

  defp assert_focused(conn, id) do
    PhoenixTest.assert_has(conn, "##{id}:focus")
  end

  defp storage_path do
    :fahrgastrechte
    |> Application.fetch_env!(Fahrgastrechte.Documents.LocalStorage)
    |> Keyword.fetch!(:path)
  end
end
