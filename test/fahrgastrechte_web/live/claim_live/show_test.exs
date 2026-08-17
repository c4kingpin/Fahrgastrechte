defmodule FahrgastrechteWeb.ClaimLive.ShowTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures, only: [document_fixture: 2]
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Tickets
  alias FahrgastrechteWeb.ClaimLive.Show
  alias FahrgastrechteWeb.UserAuth

  test "renders a scoped workspace with stable form and upload ids", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)

    assert {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")
    assert has_element?(view, "#claim-workspace")
    assert has_element?(view, "#claim-form")
    assert has_element?(view, "#document-upload-form")
    assert has_element?(view, "#ticket-suggestions")
    assert has_element?(view, "#delete-claim-button")
  end

  test "ignores a stale station search response" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        station_search_token: 2,
        origin_station_options: ["Aktueller Start"],
        destination_station_options: ["Aktuelles Ziel"]
      }
    }

    assert {:noreply, unchanged} =
             Show.handle_async(
               {:station_options, 1},
               {:ok, {["Veralteter Start"], ["Veraltetes Ziel"]}},
               socket
             )

    assert unchanged.assigns.origin_station_options == ["Aktueller Start"]
    assert unchanged.assigns.destination_station_options == ["Aktuelles Ziel"]
  end

  test "autosaves editable claim fields through the scoped context", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    view
    |> form("#claim-form",
      claim: %{
        "travel_date" => "03.08.2026",
        "origin" => "Leipzig Hbf",
        "destination" => "Dresden Hbf",
        "journey_outcome" => "aborted",
        "disruption_cause" => "cancellation",
        "journey_direction" => "return"
      }
    )
    |> render_change()

    assert {:ok, updated} = Claims.get_claim(scope, claim.id)
    assert updated.travel_date == ~D[2026-08-03]
    assert updated.origin == "Leipzig Hbf"
    assert updated.destination == "Dresden Hbf"
    assert updated.journey_outcome == :aborted
    assert updated.disruption_cause == :cancellation
    assert updated.journey_direction == :return
    assert has_element?(view, "#claim-save-state")
  end

  test "renders deterministic German date and 24-hour time formats", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope, %{"travel_date" => ~D[2026-08-02]})
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    assert has_element?(
             view,
             "#claim-travel-date[type=text][value='02.08.2026'][placeholder='TT.MM.JJJJ']"
           )

    assert has_element?(
             view,
             "#connection-departure-at[type=text][value='02.08.2026, 08:00']"
           )

    assert has_element?(
             view,
             "input[name='planned[scheduled_departure]'][type=text][value='02.08.2026, 08:00']"
           )

    # A native date/datetime-local input backs the picker overlay, but it has
    # no `name` and stays out of the submitted form data — only the visible
    # German-formatted text input above is ever submitted.
    assert has_element?(
             view,
             "#claim-travel-date-picker input[type=date][data-role='native-picker']:not([name])"
           )

    assert has_element?(
             view,
             "#connection-departure-at-picker input[type=datetime-local][data-role='native-picker']:not([name])"
           )
  end

  test "automatically uploads and analyzes a ticket, then applies a traceable route suggestion",
       %{
         conn: conn
       } do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope, %{"origin" => nil, "destination" => nil})
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    content = File.read!(fixture_path("synthetic-ticket-flexpreis.pdf"))

    upload =
      file_input(view, "#document-upload-form", :documents, [
        %{
          last_modified: 1_700_000_000_000,
          name: "mein-ticket.pdf",
          content: content,
          size: byte_size(content),
          type: "application/pdf"
        }
      ])

    render_upload(upload, "mein-ticket.pdf")
    render_async(view)

    assert has_element?(view, "#ticket-document-card #download-ticket")
    assert has_element?(view, "#ticket-document-card #reanalyze-ticket")
    assert has_element?(view, "#ticket-suggestions article")
    assert has_element?(view, "#claim-step-dokumente[data-state=incomplete]")
    assert has_element?(view, "#claim-step-vorschlaege[data-state=incomplete]")

    assert {:ok, [document]} = Documents.list_documents(scope, claim.id)
    assert document.kind == :ticket
    assert document.analysis_status == :completed

    assert {:ok, suggestions} = Tickets.list_suggestions(scope, document.id)
    origin = Enum.find(suggestions, &(&1.field == :origin))

    view
    |> element("#accept-suggestion-#{origin.id}")
    |> render_click()

    assert {:ok, updated_claim} = Claims.get_claim(scope, claim.id)
    assert updated_claim.origin == "Teststadt Hbf"
    assert {:ok, updated_suggestions} = Tickets.list_suggestions(scope, document.id)
    assert Enum.find(updated_suggestions, &(&1.id == origin.id)).state == :accepted
  end

  test "deletes a private document through the coordinated UI action", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    content = File.read!(fixture_path("synthetic-invoice.pdf"))

    upload =
      file_input(view, "#document-upload-form", :documents, [
        %{
          last_modified: 1_700_000_000_000,
          name: "rechnung.pdf",
          content: content,
          size: byte_size(content),
          type: "application/pdf"
        }
      ])

    render_upload(upload, "rechnung.pdf")
    render_async(view)

    assert has_element?(view, "#delete-document-invoice")
    assert {:ok, [document]} = Documents.list_documents(scope, claim.id)
    assert document.kind == :invoice
    assert document.analysis_status == :completed
    assert {:ok, suggestions} = Tickets.list_suggestions(scope, document.id)
    assert Enum.any?(suggestions, &(&1.field == :order_number))
    assert Enum.any?(suggestions, &(&1.field == :fare))

    view |> element("#delete-document-invoice") |> render_click()

    assert {:ok, []} = Documents.list_documents(scope, claim.id)
    assert has_element?(view, "#document-upload-form")
  end

  test "redirects a manipulated foreign claim id without revealing it", %{conn: conn} do
    {conn, _scope} = authenticated_conn(conn)
    foreign_scope = scope_fixture()
    foreign_claim = claim_fixture(foreign_scope)

    assert {:error, {:redirect, %{to: "/antraege"}}} =
             live(conn, ~p"/antraege/#{foreign_claim.id}")
  end

  test "rejects a manipulated document id from another owned claim", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    open_claim = claim_fixture(scope)
    other_claim = claim_fixture(scope)
    {other_document, other_claim} = document_fixture(scope, other_claim)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{open_claim.id}/dokumente")

    render_click(view, "delete_document", %{"id" => other_document.id})
    render_click(view, "reanalyze_document", %{"id" => other_document.id})
    render_click(view, "confirm_manual_fallback", %{"id" => other_document.id})

    assert {:ok, unchanged} = Documents.get_document(scope, other_document.id)
    assert unchanged.claim_id == other_claim.id
    assert unchanged.analysis_status == :not_started
    assert is_nil(unchanged.manual_fallback_confirmed_at)

    assert {:ok, %{suggestions: [suggestion | _suggestions]}} =
             Tickets.analyze_document(
               scope,
               other_claim.id,
               other_document.id,
               other_claim.lock_version
             )

    render_click(view, "set_suggestion_state", %{
      "id" => suggestion.id,
      "state" => "rejected"
    })

    assert {:ok, unchanged_suggestions} = Tickets.list_suggestions(scope, other_document.id)
    assert Enum.find(unchanged_suggestions, &(&1.id == suggestion.id)).state == :proposed
  end

  test "a manipulated suggestion event cannot mutate a sent claim", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {document, claim} = document_fixture(scope, claim)

    {:ok, %{suggestions: [suggestion | _suggestions]}} =
      Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

    {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
    {:ok, _sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    render_click(view, "set_suggestion_state", %{
      "id" => suggestion.id,
      "state" => "accepted"
    })

    assert has_element?(view, "#flash-error", "erneut geöffnet werden")

    assert {:ok, unchanged_suggestions} = Tickets.list_suggestions(scope, document.id)
    assert Enum.find(unchanged_suggestions, &(&1.id == suggestion.id)).state == :proposed

    assert {:ok, still_sent} = Claims.get_claim(scope, claim.id)
    assert still_sent.status == :sent
  end

  test "deletes the claim and all owned resources from the workspace", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    view |> element("#delete-claim-button") |> render_click()

    assert_redirect(view, ~p"/antraege")
    assert {:error, :not_found} = Claims.get_claim(scope, claim.id)
  end

  defp authenticated_conn(conn) do
    user = user_fixture()
    scope = Scope.for_user(user)
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)
    {conn, scope}
  end

  defp fixture_path(filename) do
    Path.expand("../../../fixtures/c00/#{filename}", __DIR__)
  end
end
