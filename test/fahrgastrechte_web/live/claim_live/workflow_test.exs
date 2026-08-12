defmodule FahrgastrechteWeb.ClaimLive.WorkflowTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.ExportsFixtures
  import Fahrgastrechte.RailFixtures
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
    |> render_change()

    assert has_element?(view, "#origin-stations option[value='Teststadt Hbf']")

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
    assert has_element?(view, "#connection-results article")

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
    assert has_element?(resumed, "#actual-journey-timeline article")
  end

  test "persists a missed connection and restores its actual journey editor", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)

    claim =
      claim_fixture(scope, %{
        "origin" => "Berlin Hbf",
        "destination" => "Hamburg Hbf",
        "disruption_cause" => "delay"
      })

    journey_fixture(scope, claim, :planned, [
      segment_attributes(%{
        actual_departure: nil,
        actual_arrival: nil,
        scheduled_departure: ~U[2026-07-15 06:00:00Z],
        scheduled_arrival: ~U[2026-07-15 09:30:00Z]
      })
    ])

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/tatsaechliche-reise")

    view |> element("#choose-missed-connection") |> render_click()

    assert has_element?(view, "#missed-connection-fields")
    assert has_element?(view, "#replacement-connection-fields")

    view
    |> form("#actual-journey-form",
      actual: %{
        "origin_name" => "Berlin Hbf",
        "interchange_name" => "Hannover Hbf",
        "destination_name" => "Hamburg Hbf",
        "train_category" => "ICE",
        "train_number" => "100",
        "scheduled_departure" => "2026-07-15T08:00",
        "scheduled_arrival" => "2026-07-15T10:00",
        "actual_departure" => "2026-07-15T08:10",
        "actual_arrival" => "2026-07-15T10:30",
        "missed_category" => "ICE",
        "missed_number" => "200",
        "missed_departure" => "2026-07-15T10:15",
        "missed_arrival" => "2026-07-15T11:30",
        "replacement_category" => "IC",
        "replacement_number" => "202",
        "replacement_departure" => "2026-07-15T10:45",
        "replacement_arrival" => "2026-07-15T12:10"
      }
    )
    |> render_submit()

    assert {:ok, journey} = Rail.get_journey(scope, claim.id, :actual)
    assert Enum.map(journey.segments, & &1.train_number) == ["100", "200", "202"]

    assert {:ok, values} = Rail.form_values(scope, claim.id)
    assert values.missed_connection.train_number == "200"
    assert values.last_used_train.train_number == "202"

    assert DateTime.compare(values.actual_destination_arrival, ~U[2026-07-15 10:10:00Z]) ==
             :eq

    {:ok, resumed, _html} = live(conn, ~p"/antraege/#{claim.id}/tatsaechliche-reise")

    assert has_element?(
             resumed,
             "#actual-journey-form input[name='actual[missed_number]'][value='200']"
           )

    assert has_element?(
             resumed,
             "#actual-journey-form input[name='actual[replacement_number]'][value='202']"
           )
  end

  test "persists a complete manual connection with an interchange", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/geplante-reise")

    view
    |> form("#planned-journey-form",
      planned: %{
        "origin_name" => "Berlin Hbf",
        "destination_name" => "München Hbf",
        "train_category" => "ICE",
        "train_number" => "700",
        "scheduled_departure" => "2026-07-15T06:00",
        "scheduled_arrival" => "2026-07-15T11:30",
        "via_name" => "Nürnberg Hbf",
        "transfer_arrival" => "2026-07-15T09:00",
        "transfer_departure" => "2026-07-15T09:20",
        "second_category" => "ICE",
        "second_number" => "525"
      }
    )
    |> render_submit()

    assert {:ok, journey} = Rail.get_journey(scope, claim.id, :planned)
    assert length(journey.segments) == 2
    assert hd(journey.segments).destination_name == "Nürnberg Hbf"
    assert List.last(journey.segments).origin_name == "Nürnberg Hbf"

    {:ok, resumed, _html} = live(conn, ~p"/antraege/#{claim.id}/geplante-reise")
    assert has_element?(resumed, "#manual-transfer-editor")
  end

  test "uses export readiness checks for assistant steps and generation", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = export_ready_fixture(scope)
    {:ok, documents} = Documents.list_documents(scope, claim.id)
    ticket = Enum.find(documents, &(&1.kind == :ticket))

    assert {:ok, %{claim: claim}} =
             Tickets.analyze_document(scope, ticket.id, claim.lock_version)

    assert {:error, %{checks: checks}} = Exports.readiness(scope, claim.id)
    refute checks.suggestions
    refute checks.review

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/pruefung")

    assert has_element?(view, "#claim-step-vorschlaege[data-state=incomplete]")
    assert has_element?(view, "#export-blocked")
    assert has_element?(view, "#generate-export-button[disabled]")
    assert has_element?(view, "#review-checklist a[href$='/vorschlaege']")
  end

  test "creates the PDF and follows ready, sent and completed statuses", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = export_ready_fixture(scope)
    {:ok, documents} = Documents.list_documents(scope, claim.id)

    suggestions =
      Enum.flat_map(documents, fn document ->
        {:ok, %{suggestions: document_suggestions}} =
          Tickets.analyze_document(scope, document.id)

        document_suggestions
      end)

    {:ok, _accepted} =
      Tickets.set_suggestion_states(scope, Enum.map(suggestions, & &1.id), :accepted)

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
    assert has_element?(view, "#official-form-review")

    view |> element("#mark-claim-sent") |> render_click()
    assert {:ok, sent} = Claims.get_claim(scope, claim.id)
    assert has_element?(view, "#claim-status-history article")
    assert sent.status == :sent

    assert has_element?(view, "#submission-checklist")
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

  test "marks invalidated output as archive until a new export exists", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    claim = export_ready_fixture(scope)

    assert {:ok, %{export: first, claim: ready}} =
             Exports.generate_export(scope, claim.id, claim.lock_version)

    assert {:ok, _draft} =
             Claims.update_claim(
               scope,
               claim.id,
               %{"destination" => "Bremen Hbf"},
               ready.lock_version
             )

    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/pruefung")

    assert has_element?(
             view,
             "#claim-exports article[data-export-id='#{first.id}'][data-current=false]"
           )

    assert has_element?(view, "#download-export-#{first.id}", "Archiv-PDF laden")
    refute has_element?(view, "#submission-checklist")
    assert has_element?(view, "#claim-step-pruefung[data-state=incomplete]")
    assert has_element?(view, "#generate-export-button:not([disabled])")

    view |> element("#generate-export-button") |> render_click()

    assert {:ok, [archived, current]} = Exports.list_exports(scope, claim.id)
    refute archived.current
    assert current.current

    assert has_element?(
             view,
             "#claim-exports article[data-export-id='#{first.id}'][data-current=false]"
           )

    assert has_element?(
             view,
             "#claim-exports article[data-export-id='#{current.id}'][data-current=true]"
           )

    assert has_element?(view, "#submission-checklist")
    assert {:ok, current_claim} = Claims.get_claim(scope, claim.id)

    assert {:ok, _deleted} =
             Documents.delete_claim(scope, claim.id, current_claim.lock_version)
  end

  defp authenticated_conn(conn) do
    user = user_fixture()
    scope = Scope.for_user(user)
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)
    {conn, scope}
  end
end
