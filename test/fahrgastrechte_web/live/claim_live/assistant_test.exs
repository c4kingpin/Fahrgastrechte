defmodule FahrgastrechteWeb.ClaimLive.AssistantTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Claims
  alias FahrgastrechteWeb.UserAuth

  @steps [
    {"falldaten", "#claim-data-section"},
    {"dokumente", "#claim-documents-section"},
    {"vorschlaege", "#ticket-suggestions-section"},
    {"geplante-reise", "#planned-journey-section"},
    {"tatsaechliche-reise", "#actual-journey-section"},
    {"pruefung", "#claim-review-export-section"}
  ]

  test "makes every assistant step directly addressable", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)

    for {slug, selector} <- @steps do
      assert {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/#{slug}")
      assert has_element?(view, "#{selector}:not([hidden])")
      assert has_element?(view, "#claim-step-#{slug}[aria-current=step]")
      assert has_element?(view, "#claim-step-mobile-navigation")

      if slug == "falldaten" do
        assert has_element?(view, "#claim-step-back[href=\"/antraege\"]")
      end
    end
  end

  test "continues at the first unfinished step using persisted domain data", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    assert {:ok, claim} = Claims.create_claim(scope, %{})

    assert {:ok, empty_view, _html} = live(conn, ~p"/antraege/#{claim.id}")
    assert has_element?(empty_view, "#claim-data-section:not([hidden])[data-state=open]")

    assert {:ok, partial} =
             Claims.update_claim(scope, claim.id, %{"origin" => "Berlin Hbf"}, claim.lock_version)

    assert {:ok, partial_view, _html} =
             live(conn, ~p"/antraege/#{claim.id}/falldaten")

    assert has_element?(partial_view, "#claim-data-section[data-state=incomplete]")

    assert {:ok, complete} =
             Claims.update_claim(
               scope,
               claim.id,
               valid_claim_attributes(),
               partial.lock_version
             )

    assert complete.origin == "Berlin Hbf"
    assert {:ok, resumed_view, _html} = live(conn, ~p"/antraege/#{claim.id}")
    assert has_element?(resumed_view, "#claim-documents-section:not([hidden])")
    assert has_element?(resumed_view, "#claim-step-falldaten[data-state=confirmed]")
    assert has_element?(resumed_view, "#claim-step-dokumente[data-state=open]")
  end

  test "patch navigation updates the visible step and announces the focus target", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/falldaten")

    view |> element("#claim-step-geplante-reise") |> render_click()

    assert_patch(view, ~p"/antraege/#{claim.id}/geplante-reise")
    assert has_element?(view, "#planned-journey-section:not([hidden])")
    assert has_element?(view, "#claim-step-back")
    assert has_element?(view, "#claim-step-forward")
    assert_push_event(view, "focus-claim-step", %{id: "planned-journey-heading"})
  end

  test "autosave exposes success, validation, saving and conflict states", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/falldaten")

    assert has_element?(view, "#claim-save-state[data-state=saved][role=status]")
    assert has_element?(view, "#claim-save-state [data-save-label=saving]")

    assert has_element?(
             view,
             ~s(#claim-form[phx-change*="claim_autosave"][phx-change*="claim-save-state"])
           )

    refute has_element?(view, ~s(#claim-form[phx-change*="set_attr"]))

    view
    |> form("#claim-form", claim: complete_params(%{"origin" => String.duplicate("B", 201)}))
    |> render_change()

    assert has_element?(view, "#claim-save-state[data-state=invalid]")

    assert {:ok, external_update} =
             Claims.update_claim(
               scope,
               claim.id,
               %{"origin" => "Extern gespeichert"},
               claim.lock_version
             )

    view
    |> form("#claim-form", claim: complete_params(%{"origin" => "Eigene Änderung"}))
    |> render_change()

    assert has_element?(view, "#claim-save-state[data-state=conflict]")
    assert {:ok, persisted} = Claims.get_claim(scope, claim.id)
    assert persisted.origin == external_update.origin
  end

  defp complete_params(overrides) do
    Map.merge(
      %{
        "travel_date" => "2026-07-15",
        "origin" => "Berlin Hbf",
        "destination" => "Hamburg Hbf",
        "journey_outcome" => "delayed_arrival",
        "disruption_cause" => "delay",
        "journey_direction" => "outbound"
      },
      overrides
    )
  end

  defp authenticated_conn(conn) do
    user = user_fixture()
    scope = Scope.for_user(user)
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)
    {conn, scope}
  end
end
