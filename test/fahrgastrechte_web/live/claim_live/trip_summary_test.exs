defmodule FahrgastrechteWeb.ClaimLive.TripSummaryTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Tickets
  alias FahrgastrechteWeb.UserAuth

  test "shows one combined trip summary and confirms every detected fact at once", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope, %{"travel_date" => nil, "origin" => nil, "destination" => nil})
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    upload_pdf(view, "ticket.pdf", "synthetic-ticket-flexpreis.pdf")
    upload_pdf(view, "rechnung.pdf", "synthetic-invoice.pdf")

    view |> element("#claim-step-forward") |> render_click()
    assert_patch(view, ~p"/antraege/#{claim.id}/vorschlaege")

    assert has_element?(view, "#trip-summary-section:not([hidden])")

    assert has_element?(
             view,
             "#trip-summary-route",
             "Teststadt Hbf → Beispielstadt Hbf (Vorschlag)"
           )

    assert has_element?(view, "#trip-summary-order-number", "000000000001")
    assert has_element?(view, "#confirm-all-facts")

    view |> element("#confirm-all-facts") |> render_click()

    assert {:ok, updated_claim} = Claims.get_claim(scope, claim.id)
    assert updated_claim.origin == "Teststadt Hbf"
    assert updated_claim.destination == "Beispielstadt Hbf"
    assert has_element?(view, "#trip-summary-route", "Teststadt Hbf → Beispielstadt Hbf")
    refute has_element?(view, "#trip-summary-route", "(Vorschlag)")

    assert {:ok, documents} = Fahrgastrechte.Documents.list_documents(scope, claim.id)

    suggestions =
      Enum.flat_map(documents, fn document ->
        {:ok, document_suggestions} = Tickets.list_suggestions(scope, document.id)
        document_suggestions
      end)

    assert suggestions != []
    assert Enum.all?(suggestions, &(&1.state == :accepted))

    refute has_element?(view, "#confirm-all-facts")
  end

  test "hides the trip summary on the documents step", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/dokumente")

    assert has_element?(view, "#trip-summary-section[hidden]")
  end

  defp upload_pdf(view, name, fixture) do
    content = File.read!(fixture_path(fixture))

    upload =
      file_input(view, "#document-upload-form", :documents, [
        %{
          last_modified: 1_700_000_000_000,
          name: name,
          content: content,
          size: byte_size(content),
          type: "application/pdf"
        }
      ])

    render_upload(upload, name)
    render_async(view)
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
