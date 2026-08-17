defmodule Fahrgastrechte.Documents.CleanupWorkerTest do
  # Drives the CleanupWorker process the application already started; the
  # shared sandbox connection (async: false) lets that other process see
  # this test's fixtures.
  use Fahrgastrechte.DataCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Claims.Claim
  alias Fahrgastrechte.Documents.CleanupWorker
  alias Fahrgastrechte.Documents.Document
  alias Fahrgastrechte.Documents.LocalStorage
  alias Fahrgastrechte.Repo

  test "sweep_now/2 finishes a claim deletion left pending by a crash" do
    scope = scope_fixture()
    claim = claim_fixture(scope)
    {document, claim} = document_fixture(scope, claim)

    assert {:ok, _marked} = Claims.mark_deleting(scope, claim.id, claim.lock_version)
    assert LocalStorage.exists?(document.storage_key)

    assert {:ok, count} = CleanupWorker.sweep_now()
    assert count >= 1

    refute LocalStorage.exists?(document.storage_key)
    assert Repo.get(Document, document.id) == nil
    assert Repo.get(Claim, claim.id) == nil
  end
end
