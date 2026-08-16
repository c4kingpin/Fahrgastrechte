defmodule FahrgastrechteWeb.ClaimLive.UiDeclutterTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.ExportsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias FahrgastrechteWeb.UserAuth

  test "shows only one progress indicator and moves status/delete under more options", %{
    conn: conn
  } do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    assert has_element?(view, "#claim-stepper")
    refute has_element?(view, "#claim-next-steps")
    refute has_element?(view, "#claim-profile-link")

    assert has_element?(view, "#claim-more-options")
    assert has_element?(view, "#claim-more-options #claim-status-actions")
    assert has_element?(view, "#claim-more-options #delete-claim-button")

    refute has_element?(view, "#claim-save-button")
  end

  test "keeps manual entry available but collapsed once data is confirmed", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = export_ready_fixture(scope)

    {:ok, planned_view, _html} = live(conn, ~p"/antraege/#{claim.id}/geplante-reise")

    assert has_element?(
             planned_view,
             "#connection-search-drawer:not([open]) #connection-search-form"
           )

    {:ok, actual_view, _html} = live(conn, ~p"/antraege/#{claim.id}/tatsaechliche-reise")

    assert has_element?(actual_view, "#actual-journey-manual:not([open]) #actual-journey-form")
  end

  test "opens manual entry while the journey is still missing", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/tatsaechliche-reise")

    assert has_element?(view, "#actual-journey-manual[open] #actual-journey-form")
  end

  defp authenticated_conn(conn) do
    user = user_fixture()
    scope = Scope.for_user(user)
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)
    {conn, scope}
  end
end
