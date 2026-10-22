defmodule FahrgastrechteWeb.Features.DashboardNavigationTest do
  use FahrgastrechteWeb.FeatureCase

  alias Fahrgastrechte.Accounts

  describe "start page for a signed-in person" do
    test "without claims it offers to start the first one and asks for the profile", %{
      conn: conn
    } do
      conn
      |> log_in(user_fixture())
      |> visit(~p"/")
      |> assert_has("#dashboard-header h1", text: "Alles auf einen Blick")
      |> assert_has("#continue-claim-empty", text: "Noch kein Antrag angelegt")
      |> assert_has("#profile-nudge", text: "Profil vervollständigen")
      |> click_link("#start-first-claim-link", "Ersten Antrag anlegen")
      |> assert_path(~p"/antraege")
      |> assert_has("#claims-dashboard")
    end

    test "continues the most recent claim and hides the nudge for a complete profile", %{
      conn: conn
    } do
      scope = scope_fixture()
      {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())
      _older = claim_fixture(scope, %{"origin" => "Köln Hbf", "destination" => "Bonn Hbf"})
      claim = claim_fixture(scope)

      conn
      |> log_in(scope)
      |> visit(~p"/")
      |> assert_has("#continue-claim", text: claim.claim_number)
      |> assert_has("#continue-claim", text: "Berlin Hbf → Hamburg Hbf")
      |> assert_has("#status-overview", text: "2")
      |> refute_has("#profile-nudge")
      |> click_link("#continue-claim-cta", "Antrag fortsetzen")
      |> assert_path(~p"/antraege/#{claim.id}")
      |> assert_has("#claim-workspace h1", text: claim.claim_number)
    end

    test "the profile nudge leads to the profile", %{conn: conn} do
      conn
      |> log_in(user_fixture())
      |> visit(~p"/")
      |> click_link("#profile-nudge-link", "Profil öffnen")
      |> assert_path(~p"/profil")
    end
  end

  test "the main navigation reaches every area and marks the current one", %{conn: conn} do
    conn
    |> log_in(user_fixture())
    |> visit(~p"/")
    |> assert_has("#home-nav-link[aria-current=page]")
    |> click_link("#claims-nav-link", "Anträge")
    |> assert_path(~p"/antraege")
    |> assert_has("#claims-nav-link[aria-current=page]")
    |> click_link("#profile-nav-link", "Profil")
    |> assert_path(~p"/profil")
    |> assert_has("#profile-nav-link[aria-current=page]")
    |> click_link("#sources-nav-link", "Datenquellen")
    |> assert_path(~p"/datenquellen")
    |> assert_has("#sources-nav-link[aria-current=page]")
    |> click("#brand-link")
    |> assert_path(~p"/")
    |> click_link("#claims-nav-link", "Anträge")
    |> click_link("#home-nav-link", "Übersicht")
    |> assert_path(~p"/")
    |> assert_has("#home-nav-link[aria-current=page]")
  end

  @tag browser_context_opts: [
         viewport: %{width: 390, height: 844},
         locale: "de-DE",
         timezone_id: "Europe/Berlin"
       ]
  test "on a phone the bottom navigation replaces the header links", %{conn: conn} do
    conn
    |> log_in(user_fixture())
    |> visit(~p"/")
    |> refute_has("#claims-nav-link")
    |> assert_has("#mobile-navigation")
    |> click_link("#mobile-claims-nav-link", "Anträge")
    |> assert_path(~p"/antraege")
    |> click_link("#mobile-profile-nav-link", "Profil")
    |> assert_path(~p"/profil")
    |> click_link("#mobile-sources-nav-link", "Daten")
    |> assert_path(~p"/datenquellen")
    |> click_link("#mobile-home-nav-link", "Übersicht")
    |> assert_path(~p"/")
  end

  test "an unknown page renders the not-found error", %{conn: conn} do
    conn
    |> visit("/gibt-es-nicht")
    |> assert_has("body", text: "Not Found")
  end
end
