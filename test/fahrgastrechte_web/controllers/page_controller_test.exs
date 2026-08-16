defmodule FahrgastrechteWeb.PageControllerTest do
  use FahrgastrechteWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Fahrgastrechte"
    assert response =~ "Einfach vorbereitet"
    assert response =~ ~s(id="home-page")
    assert response =~ ~s(id="claim-preview")
    assert response =~ ~s(id="ablauf")
    assert response =~ ~s(id="login-link")
    refute response =~ "Anmeldung folgt"
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
