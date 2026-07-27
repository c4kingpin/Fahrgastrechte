defmodule Fahrgastrechte.ExportsFixtures do
  @moduledoc false

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Rail

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures
  import Fahrgastrechte.RailFixtures

  def export_ready_fixture(scope \\ scope_fixture(), claim_attrs \\ %{}) do
    {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())
    claim = claim_fixture(scope, claim_attrs)
    {_ticket, claim} = document_fixture(scope, claim)

    {_invoice, claim} =
      document_fixture(scope, claim, :invoice, %{
        path: fixture_path("synthetic-invoice.pdf"),
        original_filename: "invoice.pdf"
      })

    {:ok, %{journey: _planned}} =
      Rail.confirm_journey(scope, claim.id, :planned, [segment_attributes()], claim.lock_version)

    actual =
      segment_attributes(%{
        actual_arrival: ~U[2026-07-15 09:15:00Z],
        fetched_at: ~U[2026-07-15 09:16:00Z]
      })

    {:ok, %{journey: _actual}} =
      Rail.confirm_journey(scope, claim.id, :actual, [actual], claim.lock_version)

    claim
  end
end
