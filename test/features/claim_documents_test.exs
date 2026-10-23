defmodule FahrgastrechteWeb.Features.ClaimDocumentsTest do
  use FahrgastrechteWeb.FeatureCase

  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Documents.Document
  alias Fahrgastrechte.Repo

  @upload_label "PDFs hierher ziehen oder auswählen"

  setup do
    scope = scope_fixture()
    claim = claim_fixture(scope, %{"travel_date" => nil, "origin" => nil, "destination" => nil})
    on_exit(fn -> File.rm_rf(storage_path()) end)
    %{scope: scope, claim: claim}
  end

  test "uploads ticket and invoice together, recognises and analyses both", %{
    conn: conn,
    scope: scope,
    claim: claim
  } do
    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}")
    |> assert_connected()
    |> assert_has("#claim-documents-section", text: "Ticket & Rechnung")
    |> assert_has("#workspace-progress-label",
      text: "Es fehlt noch: Ticket und Rechnung hochladen"
    )
    |> assert_has("#ticket-document-card", text: "Noch nicht vorhanden")
    |> upload_files(@upload_label, [fixture_path(), fixture_path("synthetic-invoice.pdf")])
    |> assert_has("#analysis-status-ticket", text: "Auswertung abgeschlossen")
    |> assert_has("#analysis-status-invoice", text: "Auswertung abgeschlossen")
    |> assert_has("#ticket-document-card", text: "synthetic-ticket-flexpreis.pdf")
    |> assert_has("#invoice-document-card", text: "synthetic-invoice.pdf")
    |> assert_has("#ticket-document-card", text: "Sicher gespeichert")
    |> refute_has("[id^=document-upload-phx]")

    assert {:ok, documents} = Documents.list_documents(scope, claim.id)
    assert documents |> Enum.map(& &1.kind) |> Enum.sort() == [:invoice, :ticket]
  end

  test "rejects a non-PDF file before upload", %{conn: conn, scope: scope, claim: claim} do
    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}")
    |> assert_connected()
    |> upload_files(@upload_label, [fixture_path("bahnvorhersage-parsed-delays.csv")])
    |> assert_has("#document-upload-form", text: "Bitte verwende ausschließlich PDF-Dateien.")
    |> click_button("Upload von bahnvorhersage-parsed-delays.csv abbrechen")
    |> refute_has("#document-upload-form", text: "bahnvorhersage-parsed-delays.csv")

    assert {:ok, []} = Documents.list_documents(scope, claim.id)
  end

  test "rejects a PDF above the size limit", %{conn: conn, scope: scope, claim: claim} do
    path = temp_file("zu-gross.pdf", :binary.copy("0", 1024 * 1024 + 1))

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}")
    |> assert_connected()
    |> upload_files(@upload_label, [path])
    |> assert_has("#document-upload-form", text: "Die PDF-Datei ist zu groß.")

    assert {:ok, []} = Documents.list_documents(scope, claim.id)
  end

  test "refuses a file that only pretends to be a PDF", %{conn: conn, scope: scope, claim: claim} do
    path = temp_file("kaputt.pdf", "Das ist kein PDF.")

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}")
    |> assert_connected()
    |> upload_files(@upload_label, [path])
    |> assert_has("#flash-error", text: "Die PDF-Datei ist beschädigt oder ungültig.")
    |> assert_has("#ticket-document-card", text: "Noch nicht vorhanden")

    assert {:ok, []} = Documents.list_documents(scope, claim.id)
  end

  test "rejects more than two files at once", %{conn: conn, scope: scope, claim: claim} do
    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}")
    |> assert_connected()
    |> upload_files(@upload_label, [
      fixture_path(),
      fixture_path("synthetic-invoice.pdf"),
      fixture_path("synthetic-ticket-flexpreis-business.pdf")
    ])
    |> assert_has("#document-upload-form", text: "Bitte wähle höchstens zwei Dateien aus.")
  end

  test "downloads a stored document", %{conn: conn, scope: scope, claim: claim} do
    {_document, claim} =
      document_fixture(scope, claim, :ticket, %{original_filename: "mein ticket.pdf"})

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/dokumente")
    |> click_link("#download-ticket", "Öffnen")
    |> assert_download(fn download ->
      assert download.name == "mein ticket.pdf"
      assert download.content == File.read!(fixture_path())
    end)
  end

  test "re-analyses a document on request", %{conn: conn, scope: scope, claim: claim} do
    {_document, claim} = document_fixture(scope, claim, :ticket)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/dokumente")
    |> assert_connected()
    |> assert_has("#analysis-status-ticket", text: "Noch nicht ausgewertet")
    |> click_button("#reanalyze-ticket", "Neu auswerten")
    |> assert_has("#flash-info", text: "Das Dokument wurde ausgewertet.")
    |> assert_has("#analysis-status-ticket", text: "Auswertung abgeschlossen")
  end

  test "moves a misclassified document to the other kind after confirmation", %{
    conn: conn,
    scope: scope,
    claim: claim
  } do
    {document, claim} = document_fixture(scope, claim, :ticket)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/dokumente")
    |> assert_connected()
    |> click_button("#change-kind-ticket", "Als DB-Rechnung einordnen")
    |> assert_has("#invoice-document-card", text: "synthetic-ticket.pdf")
    |> assert_has("#ticket-document-card", text: "Noch nicht vorhanden")

    assert {:ok, %{kind: :invoice}} = Documents.get_document(scope, document.id)
  end

  @tag accept_dialogs: false
  test "keeps the document when the deletion is cancelled and removes it when confirmed", %{
    conn: conn,
    scope: scope,
    claim: claim
  } do
    {document, claim} = document_fixture(scope, claim, :ticket)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/dokumente")
    |> assert_connected()
    |> with_dialog(
      fn %{message: "Dieses Dokument wirklich löschen?"} -> :dismiss end,
      &click_button(&1, "#delete-document-ticket", "Löschen")
    )
    |> assert_has("#ticket-document-card", text: "synthetic-ticket.pdf")
    |> with_dialog(
      fn %{message: "Dieses Dokument wirklich löschen?"} -> :accept end,
      &click_button(&1, "#delete-document-ticket", "Löschen")
    )
    |> assert_has("#flash-info", text: "Das Dokument wurde sicher gelöscht.")
    |> assert_has("#ticket-document-card", text: "Noch nicht vorhanden")

    assert {:error, :not_found} = Documents.get_document(scope, document.id)
  end

  test "lets the person continue manually after a failed analysis", %{
    conn: conn,
    scope: scope,
    claim: claim
  } do
    {document, claim} = document_fixture(scope, claim, :ticket)

    document
    |> Document.analysis_changeset(%{
      analysis_status: :failed,
      analysis_error: "timeout",
      analyzed_at: DateTime.utc_now()
    })
    |> Repo.update!()

    conn
    |> log_in(scope)
    |> visit(~p"/antraege/#{claim.id}/dokumente")
    |> assert_connected()
    |> assert_has("#analysis-status-ticket", text: "Auswertung fehlgeschlagen")
    |> click_button("#confirm-manual-fallback-ticket", "Manuell fortfahren")
    |> assert_has("#flash-info", text: "Die manuelle Eingabe wurde bestätigt.")
    |> assert_has("#analysis-status-ticket", text: "Manuell bestätigt")
    |> refute_has("#confirm-manual-fallback-ticket")
  end

  defp temp_file(name, content) do
    dir =
      Path.join(System.tmp_dir!(), "fahrgastrechte-upload-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp storage_path do
    :fahrgastrechte
    |> Application.fetch_env!(Fahrgastrechte.Documents.LocalStorage)
    |> Keyword.fetch!(:path)
  end
end
