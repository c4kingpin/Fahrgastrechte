defmodule FahrgastrechteWeb.DocumentControllerTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures

  alias FahrgastrechteWeb.UserAuth

  test "streams an owned PDF through the authenticated controller", %{conn: conn} do
    scope = scope_fixture()
    claim = claim_fixture(scope)
    {document, _claim} = document_fixture(scope, claim)

    conn =
      conn
      |> init_test_session(%{})
      |> UserAuth.log_in_user(scope.user)
      |> get(~p"/dokumente/#{document.id}/download")

    assert response(conn, 200) == File.read!(fixture_path())
    assert get_resp_header(conn, "content-type") == ["application/pdf; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "synthetic-ticket.pdf"
  end

  test "redirects unauthenticated downloads", %{conn: conn} do
    assert conn |> get(~p"/dokumente/unknown/download") |> redirected_to() == ~p"/"
  end

  test "returns 404 for foreign and malformed document ids", %{conn: conn} do
    first_scope = scope_fixture()
    second_scope = scope_fixture()
    claim = claim_fixture(second_scope)
    {document, _claim} = document_fixture(second_scope, claim)

    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(first_scope.user)

    assert conn |> get(~p"/dokumente/#{document.id}/download") |> response(404)

    malformed_conn =
      Phoenix.ConnTest.build_conn()
      |> init_test_session(%{})
      |> UserAuth.log_in_user(first_scope.user)

    assert malformed_conn |> get(~p"/dokumente/not-a-uuid/download") |> response(404)
  end
end
