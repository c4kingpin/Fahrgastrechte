defmodule FahrgastrechteWeb.ClaimLive.OrderNumberMismatchTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias FahrgastrechteWeb.UserAuth

  test "warns when ticket and invoice carry different order numbers", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    upload_pdf(view, "ticket.pdf", "synthetic-ticket-flexpreis-business.pdf")
    upload_pdf(view, "rechnung.pdf", "synthetic-invoice.pdf")

    view |> element("#claim-step-forward") |> render_click()

    assert has_element?(
             view,
             "#order-number-mismatch-warning",
             "000000000002"
           )

    assert has_element?(view, "#order-number-mismatch-warning", "000000000001")
  end

  test "stays quiet when both documents share one order number", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    upload_pdf(view, "ticket.pdf", "synthetic-ticket-flexpreis.pdf")
    upload_pdf(view, "rechnung.pdf", "synthetic-invoice.pdf")

    view |> element("#claim-step-forward") |> render_click()

    refute has_element?(view, "#order-number-mismatch-warning")
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
