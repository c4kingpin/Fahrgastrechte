defmodule FahrgastrechteWeb.Features.ClaimReviewTest do
  use FahrgastrechteWeb.FeatureCase

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Exports
  alias Fahrgastrechte.Tickets

  setup do
    on_exit(fn -> File.rm_rf(storage_path()) end)
    %{scope: scope_fixture()}
  end

  test "creates the print-ready PDF and follows the claim until it is completed", %{
    conn: conn,
    scope: scope
  } do
    claim = review_ready_fixture(scope)

    conn =
      conn
      |> log_in(scope)
      |> visit(~p"/antraege/#{claim.id}")
      |> assert_connected()
      |> assert_path(~p"/antraege/#{claim.id}")
      |> assert_has("#workspace-progress-label", text: "Bereit zur Prüfung")
      |> assert_has("#claim-review-export-section", text: "Prüfen und Gesamt-PDF erstellen")
      |> assert_has("#official-form-review", text: "Berlin Hbf → Hamburg Hbf")
      |> assert_has("#official-form-review", text: "Verspätet angekommen")
      |> refute_has("#export-blocked")
      |> refute_has("#payout-form-section")
      |> click_button("#generate-export-button", "Druckfertiges PDF erstellen")
      |> assert_has("#flash-info", text: "Das druckfertige Gesamt-PDF wurde erstellt.")
      |> assert_has("#claim-status", text: "Druckfertig")
      |> assert_has("#claim-exports article", text: "Aktuell · bereit zum Versand")
      |> assert_has("#submission-checklist", text: "Formular unterschreiben")
      |> assert_has("#generate-export-button[disabled]")

    {:ok, [export]} = Exports.list_exports(scope, claim.id)

    conn
    |> click_link("#download-export-#{export.id}", "Gesamt-PDF laden")
    |> assert_download(fn download ->
      assert download.mime_type == "application/pdf"
      assert "%PDF" <> _rest = download.content
    end)
    |> click("#flash-info")
    |> click("#claim-more-options > summary")
    |> click_button("#mark-claim-sent", "Als versendet markieren")
    |> assert_has("#flash-info", text: "Der Antrag wurde als versendet markiert.")
    |> assert_has("#claim-status", text: "Versendet")
    |> assert_has("#claim-status-history article", text: "Versendet")
    # A sent claim is frozen.
    |> click_link("#claim-step-falldaten", "Reiseverlauf")
    |> assert_has("#claim-origin[disabled]")
    |> click_button("#complete-claim", "Als erledigt markieren")
    |> assert_has("#flash-info", text: "Der Antrag wurde als erledigt markiert.")
    |> assert_has("#claim-status", text: "Erledigt")
    |> refute_has("#reopen-claim")

    assert {:ok, %{status: :completed}} = Claims.get_claim(scope, claim.id)
  end

  test "reopens a print-ready claim for editing", %{conn: conn, scope: scope} do
    claim = review_ready_fixture(scope)
    {:ok, _export} = Exports.generate_export(scope, claim.id, claim.lock_version)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/pruefung")
    |> assert_connected()
    |> assert_has("#claim-status", text: "Druckfertig")
    |> click("#claim-more-options > summary")
    |> click_button("#reopen-claim", "Erneut bearbeiten")
    |> assert_has("#flash-info", text: "Der Antrag ist wieder zur Bearbeitung geöffnet.")
    |> assert_has("#claim-status", text: "Entwurf")
    |> refute_has("#mark-claim-sent")
    |> assert_has("#generate-export-button:not([disabled])")
    |> click_link("#claim-step-falldaten", "Reiseverlauf")
    |> refute_has("#claim-origin[disabled]")
  end

  test "marks an existing PDF as outdated once the claim data changes", %{
    conn: conn,
    scope: scope
  } do
    claim = review_ready_fixture(scope)
    {:ok, %{export: export}} = Exports.generate_export(scope, claim.id, claim.lock_version)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/falldaten")
    |> assert_connected()
    |> fill_in("Zielbahnhof", with: "Bremen Hbf")
    |> assert_has("#claim-status", text: "Entwurf")
    |> click_link("#claim-step-pruefung", "Prüfung & PDF")
    |> assert_has("#download-export-#{export.id}")
    |> assert_has("#claim-exports article", text: "Veraltet – Daten wurden danach geändert")
    |> refute_has("#submission-checklist")
  end

  test "blocks the PDF while information is missing and links to the open steps", %{
    conn: conn,
    scope: scope
  } do
    claim = claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/pruefung")
    |> assert_connected()
    |> assert_has("#export-blocked", text: "Vor der PDF-Erzeugung sind noch Angaben offen.")
    |> assert_has("#api-sources-empty", text: "Keine API-Quelle gespeichert")
    |> assert_has("#generate-export-button[disabled]")
    |> click("#review-checklist div:has-text('Geplante Verbindung') a")
    |> assert_path(~p"/antraege/#{claim.id}/geplante-reise")
    |> assert_has("#planned-journey-section", text: "Verbindung und Verspätung auswählen")
  end

  test "completes the payout details inline and derives account holder and BIC", %{
    conn: conn,
    scope: scope
  } do
    claim = claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/pruefung")
    |> assert_connected()
    |> within("#payout-form", fn conn ->
      conn
      |> assert_has("#payout-country", value: "Deutschland")
      |> select("Anrede *", option: "Neutrale Anrede", exact: false)
      |> fill_in("Vorname *", with: "Erika")
      |> fill_in("Nachname *", with: "Beispiel")
      |> fill_in("Straße *", with: "Testweg")
      |> fill_in("Hausnummer *", with: "1")
      |> fill_in("Postleitzahl *", with: "10115")
      |> fill_in("Ort *", with: "Berlin")
      |> fill_in("IBAN *", with: "DE72100700000532013000")
      |> assert_has("#payout-bic", value: "DEUTDEBBXXX")
      |> assert_has("#payout-account-holder", value: "Erika Beispiel")
      # Correcting the IBAN derives the matching BIC again.
      |> fill_in("IBAN *", with: "DE89370400440532013000")
      |> assert_has("#payout-bic", value: "COBADEFFXXX")
      |> click_button("#payout-save", "Auszahlungsdaten speichern")
    end)
    |> assert_has("#flash-info", text: "Deine Auszahlungsdaten wurden gespeichert.")
    |> refute_has("#payout-form-section")
    |> assert_has("#review-checklist", text: "Reisendenprofil")

    assert {:ok, profile} = Accounts.get_profile(scope)
    assert profile.account_holder == "Erika Beispiel"
    assert profile.bic == "COBADEFFXXX"
  end

  test "keeps an account holder typed over the derived one", %{conn: conn, scope: scope} do
    claim = claim_fixture(scope)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/pruefung")
    |> assert_connected()
    |> within("#payout-form", fn conn ->
      conn
      |> select("Anrede *", option: "Frau", exact: false)
      |> fill_in("Vorname *", with: "Erika")
      |> fill_in("Nachname *", with: "Beispiel")
      |> fill_in("Kontoinhaber *", with: "Max Mustermann")
      |> fill_in("Straße *", with: "Testweg")
      |> fill_in("Hausnummer *", with: "1")
      |> fill_in("Postleitzahl *", with: "10115")
      |> fill_in("Ort *", with: "Berlin")
      |> fill_in("IBAN *", with: "DE89370400440532013000")
      |> click_button("#payout-save", "Auszahlungsdaten speichern")
    end)
    |> assert_has("#flash-info", text: "Deine Auszahlungsdaten wurden gespeichert.")

    assert {:ok, %{account_holder: "Max Mustermann"}} = Accounts.get_profile(scope)
  end

  test "reports a failed PDF generation", %{conn: conn, scope: scope} do
    claim = review_ready_fixture(scope)
    put_env_for_test(Fahrgastrechte.TestPDFBackend, fail_on: :merge)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/pruefung")
    |> assert_connected()
    |> click_button("#generate-export-button", "Druckfertiges PDF erstellen")
    |> assert_has("#flash-error", text: "Das Gesamt-PDF konnte nicht erstellt werden.")
    |> assert_has("#claim-status", text: "Entwurf")
    |> refute_has("#claim-exports article")
  end

  @tag accept_dialogs: false
  test "deletes the claim with all documents only after confirmation", %{conn: conn, scope: scope} do
    claim = claim_fixture(scope)
    {document, claim} = document_fixture(scope, claim, :ticket)
    message = "Antrag und alle zugehörigen Dokumente wirklich löschen?"

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}")
    |> assert_connected()
    |> click("#claim-more-options > summary")
    |> with_dialog(
      fn %{message: ^message} -> :dismiss end,
      &click_button(&1, "#delete-claim-button", "Antrag vollständig löschen")
    )
    |> assert_path(~p"/antraege/#{claim.id}")
    |> with_dialog(
      fn %{message: ^message} -> :accept end,
      &click_button(&1, "#delete-claim-button", "Antrag vollständig löschen")
    )
    |> assert_path(~p"/antraege")
    |> assert_has("#flash-info", text: "Der Antrag und seine Dokumente wurden gelöscht.")
    |> refute_has("#claims-#{claim.id}")

    assert {:error, :not_found} = Claims.get_claim(scope, claim.id)
    assert {:error, :not_found} = Documents.get_document(scope, document.id)
  end

  # An export-ready claim whose recognised ticket facts are all confirmed.
  defp review_ready_fixture(scope) do
    claim = export_ready_fixture(scope)
    {:ok, documents} = Documents.list_documents(scope, claim.id)

    suggestion_ids =
      Enum.flat_map(documents, fn document ->
        {:ok, current} = Claims.get_claim(scope, claim.id)

        {:ok, %{suggestions: suggestions}} =
          Tickets.analyze_document(scope, claim.id, document.id, current.lock_version)

        Enum.map(suggestions, & &1.id)
      end)

    {:ok, current} = Claims.get_claim(scope, claim.id)

    {:ok, _accepted} =
      Tickets.set_suggestion_states(
        scope,
        claim.id,
        suggestion_ids,
        :accepted,
        current.lock_version
      )

    {:ok, claim} = Claims.get_claim(scope, claim.id)
    claim
  end

  defp storage_path do
    :fahrgastrechte
    |> Application.fetch_env!(Fahrgastrechte.Documents.LocalStorage)
    |> Keyword.fetch!(:path)
  end
end
