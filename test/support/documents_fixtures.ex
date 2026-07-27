defmodule Fahrgastrechte.DocumentsFixtures do
  @moduledoc false

  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Documents.LocalStorage

  def fixture_path(name \\ "synthetic-ticket-flexpreis.pdf") do
    Path.expand("../fixtures/c00/#{name}", __DIR__)
  end

  def upload_attributes(attrs \\ %{}) do
    Map.merge(
      %{
        path: fixture_path(),
        original_filename: "synthetic-ticket.pdf",
        content_type: "application/pdf"
      },
      attrs
    )
  end

  def document_fixture(scope, claim, kind \\ :ticket, attrs \\ %{}) do
    {:ok, %{document: document, claim: updated_claim}} =
      Documents.put_document(
        scope,
        claim.id,
        kind,
        upload_attributes(attrs),
        claim.lock_version
      )

    ExUnit.Callbacks.on_exit(fn -> LocalStorage.delete(document.storage_key) end)
    {document, updated_claim}
  end
end
