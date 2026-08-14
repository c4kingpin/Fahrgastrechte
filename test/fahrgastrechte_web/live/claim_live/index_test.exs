defmodule FahrgastrechteWeb.ClaimLive.IndexTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Claims
  alias FahrgastrechteWeb.UserAuth

  test "dashboard requires an authenticated scope", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/antraege")
  end

  test "renders the empty dashboard and creates a scoped draft", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)

    assert {:ok, view, _html} = live(conn, ~p"/antraege")
    assert has_element?(view, "#claims-dashboard")
    assert has_element?(view, "#claim-filter-form")
    assert has_element?(view, "#claim-route-filter.scheme-light.bg-white.text-slate-950")
    assert has_element?(view, "#claim-number-filter.scheme-light.bg-white.text-slate-950")
    assert has_element?(view, "#claim-status-filter.scheme-light.bg-white.text-slate-950")
    assert has_element?(view, "#claims-nav-link[aria-current=page]")
    assert has_element?(view, "#mobile-navigation")
    assert has_element?(view, "#logout-link")
    assert has_element?(view, "#claims-empty")

    view |> element("#new-claim-button") |> render_click()

    assert {:ok, [claim]} = Claims.list_claims(scope)
    assert_redirect(view, ~p"/antraege/#{claim.id}")
  end

  test "streams only claims matching route, number and status filters", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    berlin = claim_fixture(scope, %{"origin" => "Berlin Hbf", "destination" => "Hamburg Hbf"})
    cologne = claim_fixture(scope, %{"origin" => "Köln Hbf", "destination" => "Bonn Hbf"})

    assert {:ok, view, _html} = live(conn, ~p"/antraege")
    assert has_element?(view, "#claims-#{berlin.id}")
    assert has_element?(view, "#claims-#{cologne.id}")

    view
    |> form("#claim-filter-form",
      filters: %{"route" => "Berlin", "claim_number" => "", "status" => "all"}
    )
    |> render_change()

    assert has_element?(view, "#claims-#{berlin.id}")
    refute has_element?(view, "#claims-#{cologne.id}")

    view
    |> form("#claim-filter-form",
      filters: %{"route" => "", "claim_number" => cologne.claim_number, "status" => "draft"}
    )
    |> render_change()

    refute has_element?(view, "#claims-#{berlin.id}")
    assert has_element?(view, "#claims-#{cologne.id}")
  end

  test "keeps scoped dashboard totals independent from list filters", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    foreign_scope = scope_fixture()

    berlin = claim_fixture(scope, %{"origin" => "Berlin Hbf", "destination" => "Hamburg Hbf"})
    cologne = claim_fixture(scope, %{"origin" => "Köln Hbf", "destination" => "Bonn Hbf"})
    _foreign = claim_fixture(foreign_scope)

    assert {:ok, view, _html} = live(conn, ~p"/antraege")
    assert has_element?(view, "#claim-stat-total", "2")
    assert has_element?(view, "#claim-stat-open", "2")
    assert has_element?(view, "#claim-stat-completed", "0")

    view
    |> form("#claim-filter-form",
      filters: %{"route" => "Berlin", "claim_number" => "", "status" => "all"}
    )
    |> render_change()

    assert has_element?(view, "#claims-#{berlin.id}")
    refute has_element?(view, "#claims-#{cologne.id}")
    assert has_element?(view, "#claim-stat-total", "2")
    assert has_element?(view, "#claim-stat-open", "2")
    assert has_element?(view, "#claim-stat-completed", "0")
  end

  test "never lists another user's claims", %{conn: conn} do
    {conn, own_scope} = authenticated_conn(conn)
    foreign_scope = scope_fixture()
    own_claim = claim_fixture(own_scope)
    foreign_claim = claim_fixture(foreign_scope)

    assert {:ok, view, _html} = live(conn, ~p"/antraege")
    assert has_element?(view, "#claims-#{own_claim.id}")
    refute has_element?(view, "#claims-#{foreign_claim.id}")
  end

  defp authenticated_conn(conn) do
    user = user_fixture()
    scope = Scope.for_user(user)
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)
    {conn, scope}
  end
end
