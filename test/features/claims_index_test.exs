defmodule FahrgastrechteWeb.Features.ClaimsIndexTest do
  use FahrgastrechteWeb.FeatureCase

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Exports

  test "starts a new claim from the empty overview", %{conn: conn} do
    scope = scope_fixture()

    conn
    |> log_in(scope)
    |> visit(~p"/antraege")
    |> assert_connected()
    |> assert_has("#claims-empty", text: "Keine passenden Anträge")
    |> assert_has("#claim-stat-total", text: "0")
    |> click_button("#new-claim-button", "Neuen Antrag beginnen")
    |> assert_has("#claim-workspace")
    |> assert_has("#claim-status", text: "Entwurf")

    assert {:ok, [claim]} = Claims.list_claims(scope)

    conn
    |> assert_path(~p"/antraege/#{claim.id}")
    |> assert_has("#claim-workspace h1", text: claim.claim_number)
  end

  test "lists the claims with counts and opens one", %{conn: conn} do
    scope = scope_fixture()
    berlin = claim_fixture(scope)
    _cologne = claim_fixture(scope, %{"origin" => "Köln Hbf", "destination" => "Bonn Hbf"})

    conn
    |> log_in(scope)
    |> visit(~p"/antraege")
    |> assert_has("#claim-stat-total", text: "2")
    |> assert_has("#claim-stat-open", text: "2")
    |> assert_has("#claim-stat-completed", text: "0")
    |> assert_has("#claims-#{berlin.id}", text: "Berlin Hbf → Hamburg Hbf")
    |> assert_has("#claims-#{berlin.id}", text: "15.07.2026")
    |> assert_has("#claims-#{berlin.id}", text: "Entwurf")
    |> refute_has("#claims-empty")
    |> click_link("#claims-#{berlin.id}", "Öffnen")
    |> assert_path(~p"/antraege/#{berlin.id}")
    |> click_link("#claims-back-link", "Alle Anträge")
    |> assert_path(~p"/antraege")
  end

  test "filters by route, claim number and status", %{conn: conn} do
    scope = scope_fixture()
    berlin = claim_fixture(scope)
    cologne = claim_fixture(scope, %{"origin" => "Köln Hbf", "destination" => "Bonn Hbf"})

    ready =
      export_ready_fixture(scope, %{"origin" => "München Hbf", "destination" => "Nürnberg Hbf"})

    {:ok, %{claim: ready}} = Exports.generate_export(scope, ready.id, ready.lock_version)

    conn
    |> log_in(scope)
    |> visit(~p"/antraege")
    |> assert_connected()
    |> fill_in("Strecke", with: "Köln")
    |> assert_has("#claims-#{cologne.id}")
    |> refute_has("#claims-#{berlin.id}")
    |> refute_has("#claims-#{ready.id}")
    |> fill_in("Strecke", with: "")
    |> fill_in("Antragsnummer", with: berlin.claim_number)
    |> assert_has("#claims-#{berlin.id}")
    |> refute_has("#claims-#{cologne.id}")
    |> fill_in("Antragsnummer", with: "")
    |> select("Status", option: "Druckfertig", exact: false)
    |> assert_has("#claims-#{ready.id}", text: "Druckfertig")
    |> refute_has("#claims-#{berlin.id}")
    |> refute_has("#claims-#{cologne.id}")
    |> select("Status", option: "Erledigt", exact: false)
    |> assert_has("#claims-empty", text: "Keine passenden Anträge")
    |> select("Status", option: "Alle Status", exact: false)
    |> assert_has("#claims-#{berlin.id}")
    |> assert_has("#claims-#{cologne.id}")
    |> assert_has("#claims-#{ready.id}")
  end

  test "only shows the claims of the signed-in person", %{conn: conn} do
    own = claim_fixture(scope_fixture())
    foreign = claim_fixture(scope_fixture())

    conn
    |> log_in(own.user_id |> Fahrgastrechte.Accounts.scope_for_user_id())
    |> visit(~p"/antraege")
    |> assert_has("#claims-#{own.id}")
    |> refute_has("#claims-#{foreign.id}")
    |> visit(~p"/antraege/#{foreign.id}")
    |> assert_path(~p"/antraege")
    |> assert_has("#flash-error", text: "Dieser Antrag wurde nicht gefunden.")
  end
end
