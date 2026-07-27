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
  end
end
