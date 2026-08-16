defmodule FahrgastrechteWeb.ClaimLive.DocumentReviewTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Tickets
  alias FahrgastrechteWeb.UserAuth

  test "reads ticket and invoice data before prefilling the case data step", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope, %{"travel_date" => nil, "origin" => nil, "destination" => nil})
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    assert has_element?(view, "#claim-documents-section:not([hidden])")

    upload_pdf(
      view,
      "#document-upload-form",
      "ticket.pdf",
      "synthetic-ticket-flexpreis.pdf"
    )

    upload_pdf(
      view,
      "#document-upload-form",
      "rechnung.pdf",
      "synthetic-invoice.pdf"
    )

    view |> element("#claim-step-forward") |> render_click()

    assert_patch(view, ~p"/antraege/#{claim.id}/vorschlaege")
    assert has_element?(view, "#ticket-suggestions-section:not([hidden])")

    assert has_element?(view, "#route-suggestions article")
    assert has_element?(view, "#booking-suggestions article")
    assert has_element?(view, "#suggestion-correction-form")

    view |> element("#accept-all-suggestions") |> render_click()

    assert {:ok, updated_claim} = Claims.get_claim(scope, claim.id)
    assert updated_claim.travel_date == ~D[2026-04-15]
    assert updated_claim.origin == "Teststadt Hbf"
    assert updated_claim.destination == "Beispielstadt Hbf"

    assert {:ok, documents} = Documents.list_documents(scope, claim.id)

    suggestions =
      Enum.flat_map(documents, fn document ->
        {:ok, document_suggestions} = Tickets.list_suggestions(scope, document.id)
        document_suggestions
      end)

    route_fields = [
      :travel_date,
      :valid_until,
      :origin,
      :destination,
      :scheduled_train,
      :scheduled_departure,
      :scheduled_arrival
    ]

    assert suggestions
           |> Enum.filter(&(&1.field in route_fields))
           |> Enum.all?(&(&1.state == :accepted))

    assert Enum.any?(suggestions, &(&1.field == :order_number and &1.state == :accepted))
    assert Enum.any?(suggestions, &(&1.field == :fare and &1.state == :accepted))

    {:ok, falldaten_view, _html} = live(conn, ~p"/antraege/#{claim.id}/falldaten")

    assert has_element?(falldaten_view, "#claim-data-section:not([hidden])")
    assert has_element?(falldaten_view, "#claim-travel-date[type=text][value='15.04.2026']")
    assert has_element?(falldaten_view, "#claim-origin[value='Teststadt Hbf']")
    assert has_element?(falldaten_view, "#claim-destination[value='Beispielstadt Hbf']")
  end

  test "replaces a stored PDF without exposing an intermediate missing state", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/dokumente")

    upload_pdf(
      view,
      "#document-upload-form",
      "ticket-alt.pdf",
      "synthetic-ticket-flexpreis.pdf"
    )

    assert {:ok, [old_document]} = Documents.list_documents(scope, claim.id)
    assert has_element?(view, "#document-upload-form")

    upload_pdf(
      view,
      "#document-upload-form",
      "ticket-neu.pdf",
      "synthetic-ticket-flexpreis-business.pdf"
    )

    assert {:ok, [new_document]} = Documents.list_documents(scope, claim.id)
    assert new_document.id != old_document.id
    assert new_document.original_filename == "ticket-neu.pdf"
    assert has_element?(view, "#ticket-document-card #download-ticket")
  end

  defp upload_pdf(view, selector, name, fixture) do
    content = File.read!(fixture_path(fixture))

    upload =
      file_input(view, selector, :documents, [
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
