defmodule FahrgastrechteWeb.PageControllerTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures

  alias Fahrgastrechte.Accounts
  alias FahrgastrechteWeb.UserAuth

  test "GET / shows the marketing page for a visitor without a session", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Fahrgastrechte"
    assert response =~ "Einfach vorbereitet"
    assert response =~ ~s(id="home-page")
    assert response =~ ~s(id="claim-preview")
    assert response =~ ~s(id="ablauf")
    assert response =~ ~s(id="login-link")
    refute response =~ "Anmeldung folgt"
    refute response =~ ~s(id="status-overview")
  end

  test "GET / shows an empty-state dashboard for a user without claims", %{conn: conn} do
    scope = scope_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> UserAuth.log_in_user(scope.user)
      |> get(~p"/")

    response = html_response(conn, 200)

    assert response =~ ~s(id="continue-claim-empty")
    assert response =~ ~s(id="start-first-claim-link")
    assert response =~ ~s(id="status-overview")
    refute response =~ ~s(id="continue-claim")
    refute response =~ ~s(id="claim-preview")
    refute response =~ "ICE 772"
    refute response =~ "Frankfurt"
  end

  test "GET / highlights the most recently edited claim for a returning user", %{conn: conn} do
    scope = scope_fixture()
    older = claim_fixture(scope, %{"origin" => "Berlin Hbf"})
    _newer = claim_fixture(scope, %{"origin" => "München Hbf"})

    {:ok, edited_older} =
      Fahrgastrechte.Claims.update_claim(
        scope,
        older.id,
        %{"travel_date" => "2026-09-01"},
        older.lock_version
      )

    conn =
      conn
      |> init_test_session(%{})
      |> UserAuth.log_in_user(scope.user)
      |> get(~p"/")

    response = html_response(conn, 200)

    assert response =~ ~s(id="continue-claim")
    assert response =~ edited_older.claim_number
    assert response =~ "Berlin Hbf"
    refute response =~ ~s(id="continue-claim-empty")
  end

  test "GET / nudges an authenticated user to complete an incomplete profile", %{conn: conn} do
    scope = scope_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> UserAuth.log_in_user(scope.user)
      |> get(~p"/")

    assert html_response(conn, 200) =~ ~s(id="profile-nudge")
  end

  test "GET / hides the profile nudge once the profile is complete", %{conn: conn} do
    scope = scope_fixture()
    {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())

    conn =
      conn
      |> init_test_session(%{})
      |> UserAuth.log_in_user(scope.user)
      |> get(~p"/")

    refute html_response(conn, 200) =~ ~s(id="profile-nudge")
  end

  test "browser responses carry a strict content security policy", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "default-src 'self'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "base-uri 'none'"

    # LiveView needs its own websocket, but nothing beyond the app's origin.
    assert policy =~ "connect-src 'self' ws: wss:"

    # Inline styles are tolerated for the progress bars; scripts never are.
    assert policy =~ "script-src 'self'"
    refute policy =~ "script-src 'self' 'unsafe-inline'"
    refute policy =~ "unsafe-eval"
  end

  test "browser responses carry a strict content security policy", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "default-src 'self'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "base-uri 'none'"

    # LiveView needs its own websocket, but nothing beyond the app's origin.
    assert policy =~ "connect-src 'self' ws: wss:"

    # Inline styles are tolerated for the progress bars; scripts never are.
    assert policy =~ "script-src 'self'"
    refute policy =~ "script-src 'self' 'unsafe-inline'"
    refute policy =~ "unsafe-eval"
  end
end
