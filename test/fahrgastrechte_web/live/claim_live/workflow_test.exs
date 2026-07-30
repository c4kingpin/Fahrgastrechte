defmodule FahrgastrechteWeb.ClaimLive.WorkflowTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.ExportsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Exports
  alias Fahrgastrechte.Rail
  alias Fahrgastrechte.TestRailProvider
  alias Fahrgastrechte.Tickets
  alias FahrgastrechteWeb.UserAuth

  setup do
    rail_config = Application.fetch_env!(:fahrgastrechte, Rail)

    Application.put_env(
      :fahrgastrechte,
      Rail,
      Keyword.put(rail_config, :provider, TestRailProvider)
    )

    on_exit(fn -> Application.put_env(:fahrgastrechte, Rail, rail_config) end)
    :ok
  end

  test "shows an API delay on the connection and adopts it with one action", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)

    claim =
      claim_fixture(scope, %{
        "travel_date" => ~D[2026-04-15],
        "origin" => "Teststadt Hbf",
        "destination" => "Beispielstadt Hbf",
        "journey_outcome" => "delayed_arrival",
        "disruption_cause" => "delay",
        "journey_direction" => "outbound"
      })

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    view
    |> form("#connection-search-form",
      connection_search: %{
        "origin" => "Teststadt Hbf",
        "destination" => "Beispielstadt Hbf",
        "departure_at" => "2026-04-15T06:00",
        "train_number" => "100"
      }
    )
    |> render_submit()

    assert has_element?(view, "#connection-delay-1[data-delay-minutes='32']")
    assert has_element?(view, "#choose-connection-1")

    view |> element("#choose-connection-1") |> render_click()

    assert {:ok, planned} = Rail.get_journey(scope, claim.id, :planned)
    assert {:ok, actual} = Rail.get_journey(scope, claim.id, :actual)
    assert hd(planned.segments).train_number == "100"

    assert DateTime.compare(
             List.last(actual.segments).estimated_arrival,
             ~U[2026-04-15 10:42:00Z]
           ) == :eq

    assert has_element?(view, "#api-delay-summary")
  end

  test "manual fallback survives interruption and completes the actual journey", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")

    view
    |> form("#planned-journey-form",
      planned: %{
        "origin_name" => "Berlin Hbf",
        "destination_name" => "Hamburg Hbf",
        "train_category" => "ICE",
        "train_number" => "100",
        "scheduled_departure" => "2026-07-15T06:00",
        "scheduled_arrival" => "2026-07-15T08:00"
      }
    )
    |> render_submit()

    assert {:ok, _planned} = Rail.get_journey(scope, claim.id, :planned)

    {:ok, resumed, _html} = live(conn, ~p"/antraege/#{claim.id}")
    assert has_element?(resumed, "#planned-journey-form")

    resumed |> element("#choose-delay") |> render_click()

    resumed
    |> form("#actual-journey-form",
      actual: %{
        "origin_name" => "Berlin Hbf",
        "destination_name" => "Hamburg Hbf",
        "train_category" => "ICE",
        "train_number" => "100",
        "scheduled_departure" => "2026-07-15T06:00",
        "scheduled_arrival" => "2026-07-15T08:00",
        "actual_departure" => "2026-07-15T06:20",
        "actual_arrival" => "2026-07-15T09:15"
      }
    )
    |> render_submit()

    assert {:ok, values} = Rail.form_values(scope, claim.id)

    assert DateTime.compare(values.actual_destination_arrival, ~U[2026-07-15 07:15:00Z]) ==
             :eq

    assert has_element?(resumed, "#actual-journey-section[data-state='confirmed']")
  end

  test "creates the PDF and follows ready, sent and completed statuses", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = export_ready_fixture(scope)
    {:ok, documents} = Documents.list_documents(scope, claim.id)
    ticket = Enum.find(documents, &(&1.kind == :ticket))
    {:ok, %{suggestions: suggestions}} = Tickets.analyze_document(scope, ticket.id)
    order_number = Enum.find(suggestions, &(&1.field == :order_number))
    {:ok, _accepted} = Tickets.set_suggestion_state(scope, order_number.id, :accepted)

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}")
    assert has_element?(view, "#generate-export-button:not([disabled])")
    assert has_element?(view, "#claim-step-dokumente[data-state=confirmed]")
    assert has_element?(view, "#claim-step-geplante-reise[data-state=confirmed]")
    assert has_element?(view, "#claim-step-tatsaechliche-reise[data-state=confirmed]")

    view |> element("#generate-export-button") |> render_click()

    assert {:ok, [export]} = Exports.list_exports(scope, claim.id)
    assert has_element?(view, "#download-export-#{export.id}")
    assert {:ok, ready} = Claims.get_claim(scope, claim.id)
    assert ready.status == :ready

    view |> element("#mark-claim-sent") |> render_click()
    assert {:ok, sent} = Claims.get_claim(scope, claim.id)
    assert sent.status == :sent

    view |> element("#complete-claim") |> render_click()
    assert {:ok, completed} = Claims.get_claim(scope, claim.id)
    assert completed.status == :completed

    assert {:ok, _deleted} = Documents.delete_claim(scope, claim.id, completed.lock_version)
  end

  test "returns from profile completion to the originating claim", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)

    {:ok, view, _html} = live(conn, ~p"/profil?antrag=#{claim.id}")
    assert has_element?(view, "#profile-back-to-claim")

    view
    |> form("#profile-form", profile: valid_profile_attributes())
    |> render_submit()

    assert_redirect(view, ~p"/antraege/#{claim.id}")
  end

  defp authenticated_conn(conn) do
    user = user_fixture()
    scope = Scope.for_user(user)
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)
    {conn, scope}
  end
end
