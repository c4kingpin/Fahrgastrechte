defmodule FahrgastrechteWeb.ClaimLive.ShowTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Tickets
  alias FahrgastrechteWeb.UserAuth

  test "renders a scoped workspace with stable form and upload ids", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)

    assert {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")
    assert has_element?(view, "#claim-workspace")
    assert has_element?(view, "#claim-form")
    assert has_element?(view, "#ticket-upload-form")
    assert has_element?(view, "#invoice-upload-form")
    assert has_element?(view, "#ticket-suggestions")
    assert has_element?(view, "#delete-claim-button")
  end

  test "autosaves editable claim fields through the scoped context", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    view
    |> form("#claim-form",
      claim: %{
        "travel_date" => "2026-08-03",
        "origin" => "Leipzig Hbf",
        "destination" => "Dresden Hbf",
        "disruption_type" => "cancellation"
      }
    )
    |> render_change()

    assert {:ok, updated} = Claims.get_claim(scope, claim.id)
    assert updated.travel_date == ~D[2026-08-03]
    assert updated.origin == "Leipzig Hbf"
    assert updated.destination == "Dresden Hbf"
    assert updated.disruption_type == :cancellation
    assert has_element?(view, "#claim-save-state")
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
      file_input(view, "#ticket-upload-form", :ticket, [
        %{
          last_modified: 1_700_000_000_000,
          name: "mein-ticket.pdf",
          content: content,
          size: byte_size(content),
          type: "application/pdf"
        }
      ])

    render_upload(upload, "mein-ticket.pdf")

    assert has_element?(view, "#ticket-document-card #download-ticket")
    assert has_element?(view, "#ticket-document-card #reanalyze-ticket")
    assert has_element?(view, "#ticket-suggestions article")

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
      file_input(view, "#invoice-upload-form", :invoice, [
        %{
          last_modified: 1_700_000_000_000,
          name: "rechnung.pdf",
          content: content,
          size: byte_size(content),
          type: "application/pdf"
        }
      ])

    render_upload(upload, "rechnung.pdf")

    assert has_element?(view, "#delete-document-invoice")
    assert {:ok, [document]} = Documents.list_documents(scope, claim.id)
    assert document.kind == :invoice
    assert document.analysis_status == :completed
    assert {:ok, suggestions} = Tickets.list_suggestions(scope, document.id)
    assert Enum.any?(suggestions, &(&1.field == :order_number))
    assert Enum.any?(suggestions, &(&1.field == :fare))

    view |> element("#delete-document-invoice") |> render_click()

    assert {:ok, []} = Documents.list_documents(scope, claim.id)
    assert has_element?(view, "#invoice-upload-form")
  end

  test "redirects a manipulated foreign claim id without revealing it", %{conn: conn} do
    {conn, _scope} = authenticated_conn(conn)
    foreign_scope = scope_fixture()
    foreign_claim = claim_fixture(foreign_scope)

    assert {:error, {:redirect, %{to: "/antraege"}}} =
             live(conn, ~p"/antraege/#{foreign_claim.id}")
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
