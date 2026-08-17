defmodule FahrgastrechteWeb.ClaimLive.ShowTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures, only: [document_fixture: 2, document_fixture: 4]
  import Fahrgastrechte.RailFixtures, only: [station_fixture!: 2]
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.TestTicketRouteExtractor
  alias Fahrgastrechte.Tickets
  alias FahrgastrechteWeb.ClaimLive.Show
  alias FahrgastrechteWeb.UserAuth

  test "renders a scoped workspace with stable form and upload ids", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)

    assert {:ok, view, html} = live(conn, ~p"/antraege/#{claim.id}")
    assert has_element?(view, "#claim-workspace")
    assert has_element?(view, "#claim-form")
    assert has_element?(view, "#document-upload-form")
    assert has_element?(view, "#ticket-suggestions")
    assert has_element?(view, "#delete-claim-button")
    assert html =~ ~s(href="#main-content")
    assert has_element?(view, "main#main-content")
  end

  test "exposes the disruption choice as a toggle button state", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope, %{"disruption_cause" => nil})
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    assert has_element?(view, "#choose-delay[aria-pressed=false]")
    assert has_element?(view, "#choose-cancellation[aria-pressed=false]")

    view |> element("#choose-delay") |> render_click()

    assert has_element?(view, "#choose-delay[aria-pressed=true]")
    assert has_element?(view, "#choose-cancellation[aria-pressed=false]")

    view |> element("#choose-cancellation") |> render_click()

    assert has_element?(view, "#choose-delay[aria-pressed=false]")
    assert has_element?(view, "#choose-cancellation[aria-pressed=true]")
  end

  test "ignores a stale station field search response but still clears pending" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        station_field_tokens: %{"claim-origin" => 2},
        station_field_options: %{"claim-origin" => [%{name: "Aktueller Treffer", id: nil}]},
        station_field_pending: MapSet.new(["claim-origin"])
      }
    }

    assert {:noreply, unchanged} =
             Show.handle_async(
               {:station_field_options, 1},
               {:ok, {"claim-origin", {:ok, [%{name: "Veralteter Treffer", id: nil}]}}},
               socket
             )

    assert unchanged.assigns.station_field_options == %{
             "claim-origin" => [%{name: "Aktueller Treffer", id: nil}]
           }

    refute MapSet.member?(unchanged.assigns.station_field_pending, "claim-origin")
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

  test "claim form station fields offer a live combobox fed by the local catalog",
       %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    station_fixture!("Leipzig Hbf", "8010205")
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    view
    |> form("#claim-form", claim: %{"origin" => "Leipzig"})
    |> render_change()

    render_async(view)

    assert has_element?(view, "#claim-origin-option-0", "Leipzig Hbf")

    view
    |> element("#claim-origin-option-0")
    |> render_click()

    assert {:ok, updated} = Claims.get_claim(scope, claim.id)
    assert updated.origin == "Leipzig Hbf"
  end

  test "manual correction, planned-journey and actual-journey station fields also use the combobox",
       %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    station_fixture!("Leipzig Hbf", "8010205")
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    view
    |> form("#suggestion-correction-form", correction: %{"origin" => "Leipzig"})
    |> render_change()

    render_async(view)

    assert has_element?(view, "#correction-origin-option-0", "Leipzig Hbf")

    view
    |> form("#planned-journey-form", planned: %{"origin_name" => "Leipzig"})
    |> render_change()

    render_async(view)

    assert has_element?(view, "#planned-origin_name-option-0", "Leipzig Hbf")

    view
    |> form("#actual-journey-form", actual: %{"origin_name" => "Leipzig"})
    |> render_change()

    render_async(view)

    assert has_element?(view, "#actual-origin_name-option-0", "Leipzig Hbf")
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
    assert has_element?(view, "#analysis-status-ticket[role=status]")
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

  test "manual station search box finds and applies a real catalog match", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)

    tickets_config = Application.fetch_env!(:fahrgastrechte, Tickets)

    Application.put_env(
      :fahrgastrechte,
      Tickets,
      Keyword.put(tickets_config, :extractor, TestTicketRouteExtractor)
    )

    on_exit(fn -> Application.put_env(:fahrgastrechte, Tickets, tickets_config) end)

    station_fixture!("Hannover Hbf", "8000152")
    station_fixture!("Frankfurt(M) Flughafen Fernbf", "8070003")
    station_fixture!("Frankfurt(M) Flughafen Regionalbf", "8070004")

    claim = claim_fixture(scope)
    {document, claim} = document_fixture(scope, claim)

    assert {:ok, %{suggestions: suggestions}} =
             Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

    destination = Enum.find(suggestions, &(&1.field == :destination))

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    assert has_element?(view, "#station-search-toggle-#{destination.id}[aria-expanded=true]")

    view
    |> form("#station-search-form-#{destination.id}", %{"query" => "Frankfurt"})
    |> render_change()

    render_async(view)

    assert has_element?(
             view,
             "#station-option-#{destination.id}-0",
             "Frankfurt(M) Flughafen Fernbf"
           )

    assert has_element?(
             view,
             "#station-option-#{destination.id}-1",
             "Frankfurt(M) Flughafen Regionalbf"
           )

    view
    |> element("#station-option-#{destination.id}-1")
    |> render_click()

    assert {:ok, [chosen]} =
             Tickets.list_suggestions(scope, document.id)
             |> then(fn {:ok, all} -> {:ok, Enum.filter(all, &(&1.id == destination.id))} end)

    assert chosen.value["text"] == "Frankfurt(M) Flughafen Regionalbf"
  end

  test "manual station search box can be collapsed and reopened without losing results",
       %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)

    tickets_config = Application.fetch_env!(:fahrgastrechte, Tickets)

    Application.put_env(
      :fahrgastrechte,
      Tickets,
      Keyword.put(tickets_config, :extractor, TestTicketRouteExtractor)
    )

    on_exit(fn -> Application.put_env(:fahrgastrechte, Tickets, tickets_config) end)

    station_fixture!("Hannover Hbf", "8000152")
    station_fixture!("Frankfurt(M) Flughafen Fernbf", "8070003")

    claim = claim_fixture(scope)
    {document, claim} = document_fixture(scope, claim)

    assert {:ok, %{suggestions: suggestions}} =
             Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

    destination = Enum.find(suggestions, &(&1.field == :destination))

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    assert has_element?(view, "#station-search-panel-#{destination.id}")

    view
    |> element("#station-search-toggle-#{destination.id}")
    |> render_click()

    refute has_element?(view, "#station-search-panel-#{destination.id}")
    assert has_element?(view, "#station-search-toggle-#{destination.id}[aria-expanded=false]")

    view
    |> element("#station-search-toggle-#{destination.id}")
    |> render_click()

    assert has_element?(view, "#station-search-panel-#{destination.id}")

    assert has_element?(
             view,
             "#station-option-#{destination.id}-0",
             "Frankfurt(M) Flughafen Fernbf"
           )
  end

  test "manual station search box shows a clear empty state for no matches", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)

    tickets_config = Application.fetch_env!(:fahrgastrechte, Tickets)

    Application.put_env(
      :fahrgastrechte,
      Tickets,
      Keyword.put(tickets_config, :extractor, TestTicketRouteExtractor)
    )

    on_exit(fn -> Application.put_env(:fahrgastrechte, Tickets, tickets_config) end)

    claim = claim_fixture(scope)
    {document, claim} = document_fixture(scope, claim)

    assert {:ok, %{suggestions: suggestions}} =
             Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

    destination = Enum.find(suggestions, &(&1.field == :destination))

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    view
    |> form("#station-search-form-#{destination.id}", %{"query" => "Nirgendwo"})
    |> render_change()

    render_async(view)

    assert has_element?(view, "#station-search-panel-#{destination.id}", "Keine Bahnhöfe gefunden.")
  end

  test "searching a different station replaces stale results instead of being crowded out",
       %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)

    tickets_config = Application.fetch_env!(:fahrgastrechte, Tickets)

    Application.put_env(
      :fahrgastrechte,
      Tickets,
      Keyword.put(tickets_config, :extractor, TestTicketRouteExtractor)
    )

    on_exit(fn -> Application.put_env(:fahrgastrechte, Tickets, tickets_config) end)

    # Six Frankfurt Flughafen-ish stations so the destination suggestion's
    # seeded candidates alone already fill the old 6-slot merge cap -- a
    # differently named station typed afterwards must still show up.
    for n <- 1..6 do
      station_fixture!("Frankfurt(M) Flughafen Gate #{n}", "807000#{n}")
    end

    station_fixture!("Frankfurt(Main)Hbf", "8000105")

    claim = claim_fixture(scope)
    {document, claim} = document_fixture(scope, claim)

    assert {:ok, %{suggestions: suggestions}} =
             Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

    destination = Enum.find(suggestions, &(&1.field == :destination))

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    view
    |> form("#station-search-form-#{destination.id}", %{"query" => "Frankfurt(Main)Hbf"})
    |> render_change()

    render_async(view)

    assert has_element?(
             view,
             "#station-search-panel-#{destination.id}",
             "Frankfurt(Main)Hbf"
           )

    view
    |> element("#station-option-#{destination.id}-0")
    |> render_click()

    assert {:ok, [chosen]} =
             Tickets.list_suggestions(scope, document.id)
             |> then(fn {:ok, all} -> {:ok, Enum.filter(all, &(&1.id == destination.id))} end)

    assert chosen.value["text"] == "Frankfurt(Main)Hbf"
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
    render_click(view, "change_document_kind", %{"id" => other_document.id, "kind" => "invoice"})
    render_click(view, "confirm_manual_fallback", %{"id" => other_document.id})

    assert {:ok, unchanged} = Documents.get_document(scope, other_document.id)
    assert unchanged.claim_id == other_claim.id
    assert unchanged.analysis_status == :not_started
    assert unchanged.kind == :ticket
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

  test "corrects a misclassified document's kind and reanalyzes it in place", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)

    {document, claim} =
      document_fixture(scope, claim, :ticket, %{
        path: fixture_path("synthetic-invoice.pdf"),
        original_filename: "invoice.pdf"
      })

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/dokumente")

    assert has_element?(view, "#ticket-document-card #change-kind-ticket")

    view |> element("#change-kind-ticket") |> render_click()
    render_async(view)

    assert has_element?(view, "#invoice-document-card #download-invoice")
    refute has_element?(view, "#ticket-document-card #download-ticket")

    assert {:ok, relabeled} = Documents.get_document(scope, document.id)
    assert relabeled.kind == :invoice
    assert relabeled.analysis_status == :completed

    assert {:ok, suggestions} = Tickets.list_suggestions(scope, document.id)
    assert Enum.any?(suggestions, &(&1.field == :order_number))
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
