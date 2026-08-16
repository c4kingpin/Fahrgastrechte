defmodule FahrgastrechteWeb.ClaimLive.RequiredInputsTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.ExportsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.ClaimWorkspace
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Tickets
  alias FahrgastrechteWeb.UserAuth

  test "names the next open question and opens straight to it", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    assert has_element?(
             view,
             "#workspace-progress-label",
             "Es fehlt noch: Ticket und Rechnung hochladen"
           )

    assert has_element?(view, "#claim-documents-section:not([hidden])")
  end

  test "shows readiness and resumes at review once every question is answered", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = export_ready_fixture(scope)

    assert {:ok, documents} = Documents.list_documents(scope, claim.id)

    suggestions =
      Enum.flat_map(documents, fn document ->
        assert {:ok, %{suggestions: document_suggestions}} =
                 Tickets.analyze_document(scope, claim.id, document.id)

        document_suggestions
      end)

    assert {:ok, _result} = ClaimWorkspace.accept_suggestions(scope, claim, suggestions)

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    assert has_element?(view, "#workspace-progress-label", "Bereit zur Prüfung")
    assert has_element?(view, "#claim-review-export-section:not([hidden])")
  end

  defp authenticated_conn(conn) do
    user = user_fixture()
    scope = Scope.for_user(user)
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)
    {conn, scope}
  end
end
