defmodule Fahrgastrechte.ExportsFixtures do
  @moduledoc false

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Rail
  alias Fahrgastrechte.Tickets

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures
  import Fahrgastrechte.RailFixtures

  def export_ready_fixture(scope \\ scope_fixture(), claim_attrs \\ %{}) do
    {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())
    claim = claim_fixture(scope, claim_attrs)
    {ticket, claim} = document_fixture(scope, claim)

    {invoice, claim} =
      document_fixture(scope, claim, :invoice, %{
        path: fixture_path("synthetic-invoice.pdf"),
        original_filename: "invoice.pdf"
      })

    claim = review_document_fixture(scope, ticket, claim)
    claim = review_document_fixture(scope, invoice, claim)

    {:ok, %{journey: _planned, claim: claim}} =
      Rail.confirm_journey(scope, claim.id, :planned, [segment_attributes()], claim.lock_version)

    actual =
      segment_attributes(%{
        actual_arrival: ~U[2026-07-15 09:15:00Z],
        fetched_at: ~U[2026-07-15 09:16:00Z]
      })

    {:ok, %{journey: _actual, claim: claim}} =
      Rail.confirm_journey(scope, claim.id, :actual, [actual], claim.lock_version)

    claim
  end

  def review_document_fixture(scope, document, claim) do
    {:ok, %{suggestions: suggestions, claim: claim}} =
      Tickets.analyze_document(scope, document.id, claim.lock_version)

    case suggestions do
      [] ->
        claim

      suggestions ->
        {:ok, %{claim: claim}} =
          Tickets.set_suggestion_states(
            scope,
            Enum.map(suggestions, & &1.id),
            :rejected,
            claim.lock_version
          )

        claim
    end
  end
end
