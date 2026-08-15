defmodule FahrgastrechteWeb.ClaimLive.AutoConnectionTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Rail
  alias Fahrgastrechte.TestRailProvider
  alias FahrgastrechteWeb.UserAuth

  setup do
    rail_config = Application.fetch_env!(:fahrgastrechte, Rail)

    Application.put_env(
      :fahrgastrechte,
      Rail,
      Keyword.put(rail_config, :provider, TestRailProvider)
    )

    on_exit(fn -> Application.put_env(:fahrgastrechte, Rail, rail_config) end)
    :ok
  end

  test "confirming ticket facts automatically reconstructs the single matching connection", %{
    conn: conn
  } do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope, %{"travel_date" => nil, "origin" => nil, "destination" => nil})
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    upload_pdf(view, "ticket.pdf", "synthetic-ticket-flexpreis.pdf")
    upload_pdf(view, "rechnung.pdf", "synthetic-invoice.pdf")

    view |> element("#claim-step-forward") |> render_click()
    assert_patch(view, ~p"/antraege/#{claim.id}/vorschlaege")

    view |> element("#confirm-all-facts") |> render_click()
    render_async(view)

    assert {:ok, planned} = Rail.get_journey(scope, claim.id, :planned)
    assert {:ok, actual} = Rail.get_journey(scope, claim.id, :actual)
    assert hd(planned.segments).train_number == "100"

    assert DateTime.compare(
             List.last(actual.segments).estimated_arrival,
             ~U[2026-04-15 10:42:00Z]
           ) == :eq

    assert has_element?(view, "#trip-summary-scheduled", "15.04.2026")
    refute has_element?(view, "#trip-summary-scheduled", "Noch offen")
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
