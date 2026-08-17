defmodule Fahrgastrechte.DocumentsTest do
  use Fahrgastrechte.DataCase, async: false

  import Bitwise
  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Documents.Document
  alias Fahrgastrechte.Documents.LocalStorage
  alias Fahrgastrechte.Repo

  describe "PDF storage" do
    test "stores a valid PDF under an opaque private key and streams exact bytes" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:ok, %{document: document, claim: returned_claim}} =
               Documents.put_document(
                 scope,
                 claim.id,
                 :ticket,
                 upload_attributes(%{original_filename: "../unsafe/../../ticket.pdf"}),
                 claim.lock_version
               )

      on_exit(fn -> LocalStorage.delete(document.storage_key) end)

      assert document.original_filename == "ticket.pdf"
      assert document.mime_type == "application/pdf"
      assert document.page_count == 1
      assert document.size_bytes == File.stat!(fixture_path()).size
      assert byte_size(document.sha256) == 32
      assert document.sha256 == :crypto.hash(:sha256, File.read!(fixture_path()))
      assert document.storage_key =~ ~r/\A[0-9a-f]{64}\z/
      assert returned_claim.id == claim.id
      assert returned_claim.lock_version == claim.lock_version + 1

      assert {:error, :stale} =
               Documents.put_document(
                 scope,
                 claim.id,
                 :invoice,
                 upload_attributes(),
                 claim.lock_version
               )

      assert {:ok, %{stream: stream}} = Documents.stream_document(scope, document.id)
      assert stream |> Enum.to_list() |> IO.iodata_to_binary() == File.read!(fixture_path())

      root = storage_root()

      stored_path =
        Path.join([root, String.slice(document.storage_key, 0, 2), document.storage_key])

      assert (File.stat!(root).mode &&& 0o777) == 0o700
      assert (File.stat!(stored_path).mode &&& 0o777) == 0o600
      refute String.starts_with?(stored_path, Path.expand("priv/static"))
    end

    test "rejects false MIME declarations, corrupt PDFs and oversized files" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:error, :wrong_content_type} =
               Documents.put_document(
                 scope,
                 claim.id,
                 :ticket,
                 upload_attributes(%{content_type: "text/plain"}),
                 claim.lock_version
               )

      corrupt_path = temporary_file("corrupt.pdf", "%PDF-1.4\nnot a real PDF")

      assert {:error, :invalid_pdf} =
               Documents.put_document(
                 scope,
                 claim.id,
                 :ticket,
                 upload_attributes(%{path: corrupt_path}),
                 claim.lock_version
               )

      limit = documents_config(:max_file_size_bytes)
      oversized_path = temporary_file("oversized.pdf", "%PDF-1.4\n" <> :binary.copy("x", limit))

      assert {:error, :file_too_large} =
               Documents.put_document(
                 scope,
                 claim.id,
                 :ticket,
                 upload_attributes(%{path: oversized_path}),
                 claim.lock_version
               )

      assert {:ok, []} = Documents.list_documents(scope, claim.id)
    end

    test "enforces the configured page limit" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      output_path = temporary_path("too-many-pages.pdf")
      inputs = List.duplicate(fixture_path(), documents_config(:max_page_count) + 1)
      {_output, 0} = System.cmd("pdfunite", inputs ++ [output_path], stderr_to_stdout: true)

      assert {:error, :too_many_pages} =
               Documents.put_document(
                 scope,
                 claim.id,
                 :ticket,
                 upload_attributes(%{path: output_path}),
                 claim.lock_version
               )
    end

    test "rejects invalid document kinds without creating metadata" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:error, :invalid_kind} =
               Documents.put_document(
                 scope,
                 claim.id,
                 "../../ticket",
                 upload_attributes(),
                 claim.lock_version
               )

      assert Repo.aggregate(Document, :count) == 0
    end
  end

  describe "replacement, invalidation and deletion" do
    test "keeps exactly one current ticket and removes the replaced file" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {first, claim} = document_fixture(scope, claim)

      assert {:ok, %{document: second}} =
               Documents.put_document(
                 scope,
                 claim.id,
                 :ticket,
                 upload_attributes(%{
                   path: fixture_path("synthetic-ticket-flexpreis-business.pdf"),
                   original_filename: "replacement.pdf"
                 }),
                 claim.lock_version
               )

      on_exit(fn -> LocalStorage.delete(second.storage_key) end)

      assert second.id != first.id
      assert {:error, :not_found} = Documents.get_document(scope, first.id)
      refute LocalStorage.exists?(first.storage_key)
      assert Repo.get(Document, first.id) == nil
      assert {:ok, [listed]} = Documents.list_documents(scope, claim.id)
      assert listed.id == second.id
    end

    test "retains earlier generated versions for scoped historical downloads" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {first, claim} = document_fixture(scope, claim, :generated_bundle)

      assert {:ok, %{document: second}} =
               Documents.put_document(
                 scope,
                 claim.id,
                 :generated_bundle,
                 upload_attributes(%{
                   path: fixture_path("synthetic-ticket-flexpreis-business.pdf"),
                   original_filename: "bundle-v2.pdf"
                 }),
                 claim.lock_version
               )

      on_exit(fn -> LocalStorage.delete(second.storage_key) end)

      assert LocalStorage.exists?(first.storage_key)
      assert {:ok, historical} = Documents.get_document(scope, first.id)
      assert historical.current == false
      assert {:ok, %{stream: stream}} = Documents.stream_document(scope, first.id)
      assert stream |> Enum.to_list() |> IO.iodata_to_binary() == File.read!(fixture_path())

      assert {:ok, [current]} = Documents.list_documents(scope, claim.id)
      assert current.id == second.id
      assert current.current == true
    end

    test "document changes atomically invalidate a ready output" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)

      assert {:ok, %{document: document, claim: draft}} =
               Documents.put_document(
                 scope,
                 claim.id,
                 :invoice,
                 upload_attributes(%{
                   path: fixture_path("synthetic-invoice.pdf"),
                   original_filename: "invoice.pdf"
                 }),
                 ready.lock_version
               )

      on_exit(fn -> LocalStorage.delete(document.storage_key) end)
      assert draft.status == :draft
      assert draft.generated_at == nil

      assert {:ok, history} = Claims.list_status_history(scope, claim.id)
      assert List.last(history).reason == "dependent_data_changed"
    end

    test "deletes metadata and file idempotently" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      assert {:ok, returned_claim} =
               Documents.delete_document(scope, claim.id, document.id, claim.lock_version)

      assert returned_claim.id == claim.id
      refute LocalStorage.exists?(document.storage_key)
      assert Repo.get(Document, document.id) == nil

      assert {:ok, :already_deleted} =
               Documents.delete_document(scope, claim.id, document.id, claim.lock_version)
    end

    test "coordinates claim deletion after removing every physical document" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {ticket, claim} = document_fixture(scope, claim)

      {invoice, claim} =
        document_fixture(scope, claim, :invoice, %{
          path: fixture_path("synthetic-invoice.pdf"),
          original_filename: "invoice.pdf"
        })

      assert {:ok, deleted_claim} = Documents.delete_claim(scope, claim.id, claim.lock_version)
      assert deleted_claim.id == claim.id
      refute LocalStorage.exists?(ticket.storage_key)
      refute LocalStorage.exists?(invoice.storage_key)
      assert Repo.aggregate(Document, :count) == 0
      assert {:error, :not_found} = Claims.get_claim(scope, claim.id)
    end

    test "a stale claim deletion leaves metadata and physical files untouched" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      assert {:ok, updated_claim} =
               Claims.update_claim(
                 scope,
                 claim.id,
                 %{"destination" => "Bremen Hbf"},
                 claim.lock_version
               )

      assert {:error, :stale} = Documents.delete_claim(scope, claim.id, claim.lock_version)
      assert LocalStorage.exists?(document.storage_key)
      assert {:ok, ^document} = Documents.get_document(scope, document.id)
      assert {:ok, ^updated_claim} = Claims.get_claim(scope, claim.id)
    end
  end

  describe "change_document_kind/5" do
    test "relabels the document and invalidates a ready output atomically" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim, :ticket)
      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)

      assert {:ok, %{document: relabeled, claim: draft}} =
               Documents.change_document_kind(
                 scope,
                 claim.id,
                 document.id,
                 :invoice,
                 ready.lock_version
               )

      assert relabeled.id == document.id
      assert relabeled.kind == :invoice
      assert draft.status == :draft
      assert draft.generated_at == nil

      assert {:ok, history} = Claims.list_status_history(scope, claim.id)
      assert List.last(history).reason == "dependent_data_changed"
    end

    test "rejects the change when the claim already has a current document of the target kind" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {ticket, claim} = document_fixture(scope, claim, :ticket)

      {_invoice, claim} =
        document_fixture(scope, claim, :invoice, %{
          path: fixture_path("synthetic-invoice.pdf"),
          original_filename: "invoice.pdf"
        })

      assert {:error, :kind_taken} =
               Documents.change_document_kind(
                 scope,
                 claim.id,
                 ticket.id,
                 :invoice,
                 claim.lock_version
               )

      assert {:ok, unchanged} = Documents.get_document(scope, ticket.id)
      assert unchanged.kind == :ticket
    end

    test "reports a stale claim without changing the document" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim, :ticket)

      assert {:ok, _updated_claim} =
               Claims.update_claim(
                 scope,
                 claim.id,
                 %{"destination" => "Bremen Hbf"},
                 claim.lock_version
               )

      assert {:error, :stale} =
               Documents.change_document_kind(
                 scope,
                 claim.id,
                 document.id,
                 :invoice,
                 claim.lock_version
               )

      assert {:ok, unchanged} = Documents.get_document(scope, document.id)
      assert unchanged.kind == :ticket
    end
  end

  describe "scope isolation and persistence" do
    test "user A cannot list, read, stream or delete user B's document" do
      first_scope = scope_fixture()
      second_scope = scope_fixture()
      second_claim = claim_fixture(second_scope)
      {document, second_claim} = document_fixture(second_scope, second_claim)

      assert {:error, :not_found} = Documents.get_document(first_scope, document.id)
      assert {:error, :not_found} = Documents.stream_document(first_scope, document.id)
      assert {:error, :not_found} = Documents.list_documents(first_scope, second_claim.id)

      assert {:error, :not_found} =
               Documents.delete_document(
                 first_scope,
                 second_claim.id,
                 document.id,
                 second_claim.lock_version
               )

      assert {:ok, ^document} = Documents.get_document(second_scope, document.id)
    end

    test "rejects a document mutation bound to another owned claim" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      other_claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim)

      assert {:error, :not_found} =
               Documents.delete_document(
                 scope,
                 other_claim.id,
                 document.id,
                 other_claim.lock_version
               )

      assert {:ok, ^document} = Documents.get_document(scope, document.id)
    end

    test "stored originals remain readable without process-local state" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim)

      assert {:ok, reloaded} = Documents.get_document(scope, document.id)
      assert reloaded.storage_key == document.storage_key
      assert LocalStorage.exists?(reloaded.storage_key)

      assert {:ok, stream} = LocalStorage.stream(reloaded.storage_key, 113)
      assert stream |> Enum.to_list() |> IO.iodata_to_binary() == File.read!(fixture_path())
    end

    test "requires current_scope for every public operation" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim)

      assert {:error, :not_authenticated} = Documents.get_document(nil, document.id)
      assert {:error, :not_authenticated} = Documents.list_documents(nil, claim.id)
      assert {:error, :not_authenticated} = Documents.stream_document(nil, document.id)

      assert {:error, :not_authenticated} =
               Documents.delete_document(nil, claim.id, document.id, 1)
    end
  end

  defp temporary_file(name, contents) do
    path = temporary_path(name)
    File.write!(path, contents, [:binary])
    path
  end

  describe "cleanup_pending_documents/0" do
    test "reading documents does not delete anything" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      # Mark the row pending as a failed physical deletion would have left it.
      document
      |> Ecto.Changeset.change(
        current: false,
        deletion_pending_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )
      |> Repo.update!()

      assert {:ok, []} = Documents.list_documents(scope, claim.id)

      # The read path must leave the row and its file untouched.
      assert Repo.get(Document, document.id)
      assert LocalStorage.exists?(document.storage_key)
    end

    test "the sweep removes the file and the row" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim)

      document
      |> Ecto.Changeset.change(
        current: false,
        deletion_pending_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )
      |> Repo.update!()

      assert {:ok, 1} = Documents.cleanup_pending_documents()

      refute Repo.get(Document, document.id)
      refute LocalStorage.exists?(document.storage_key)
    end

    test "is idempotent and ignores documents that are not pending" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim)

      assert {:ok, 0} = Documents.cleanup_pending_documents()
      assert {:ok, 0} = Documents.cleanup_pending_documents()

      assert Repo.get(Document, document.id)
      assert LocalStorage.exists?(document.storage_key)
    end
  end

  defp temporary_path(name) do
    path = Path.join(System.tmp_dir!(), "c03-#{System.unique_integer([:positive])}-#{name}")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp storage_root do
    :fahrgastrechte
    |> Application.fetch_env!(LocalStorage)
    |> Keyword.fetch!(:path)
  end

  defp documents_config(key) do
    :fahrgastrechte
    |> Application.fetch_env!(Documents)
    |> Keyword.fetch!(key)
  end
end
