defmodule FahrgastrechteWeb.ClaimLive.UiDeclutterTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
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

  defp authenticated_conn(conn) do
    user = user_fixture()
    scope = Scope.for_user(user)
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)
    {conn, scope}
  end
end
