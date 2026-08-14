defmodule Fahrgastrechte.ClaimWorkspaceTest do
  use Fahrgastrechte.DataCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.ClaimWorkspace
  alias Fahrgastrechte.Tickets

  describe "load/2" do
    test "builds one checked snapshot for the scoped workspace" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:ok, workspace} = ClaimWorkspace.load(scope, claim.id)

      assert workspace.claim.id == claim.id
      assert workspace.claim_changeset.data.id == claim.id
      assert workspace.documents_by_kind == %{}
      assert workspace.documents_by_id == %{}
      assert workspace.suggestions_by_id == %{}
      assert workspace.suggestion_groups == %{route: [], booking: [], other: []}
      assert workspace.planned_journey == nil
      assert workspace.actual_journey == nil
      assert workspace.status_history != []
      assert workspace.step_states.claim == :confirmed
      assert workspace.step_states.documents == :open
      refute workspace.review_complete?
      assert {:error, %{type: :incomplete}} = workspace.readiness
    end

    test "does not expose another user's workspace" do
      owner_scope = scope_fixture()
      foreign_scope = scope_fixture()
      claim = claim_fixture(owner_scope)

      assert {:error, :not_found} = ClaimWorkspace.load(foreign_scope, claim.id)
      assert {:error, :not_authenticated} = ClaimWorkspace.load(nil, claim.id)
    end
  end

  describe "accept_suggestions/3" do
    test "rolls back claim values when any suggestion is outside the checked set" do
      scope = scope_fixture()
      initial_claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, initial_claim)

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id)

      origin = Enum.find(suggestions, &(&1.field == :origin))
      forged = %{origin | id: Ecto.UUID.generate()}

      assert {:error, :not_found} =
               ClaimWorkspace.accept_suggestions(scope, claim, [origin, forged])

      assert {:ok, unchanged} = Claims.get_claim(scope, claim.id)
      assert unchanged.origin == claim.origin
      assert unchanged.lock_version == claim.lock_version

      assert {:ok, current_suggestions} = Tickets.list_claim_suggestions(scope, claim.id)
      assert Enum.find(current_suggestions, &(&1.id == origin.id)).state == :proposed
    end

    test "updates the claim and suggestion together" do
      scope = scope_fixture()
      initial_claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, initial_claim)

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id)

      origin = Enum.find(suggestions, &(&1.field == :origin))

      assert {:ok, %{claim: updated, suggestions: [accepted]}} =
               ClaimWorkspace.accept_suggestions(scope, claim, [origin])

      assert updated.origin == "Teststadt Hbf"
      assert accepted.id == origin.id
      assert accepted.state == :accepted
    end
  end
end
