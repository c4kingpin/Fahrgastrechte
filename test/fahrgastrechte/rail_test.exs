defmodule Fahrgastrechte.RailTest do
  use Fahrgastrechte.DataCase, async: true

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.RailFixtures

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Rail
  alias Fahrgastrechte.TestRailProvider

  describe "provider boundary and snapshots" do
    test "returns unconfirmed normalized candidates and persists immutable snapshots" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:ok, [station]} =
               Rail.search_stations(scope, claim.id, "Teststadt", provider: TestRailProvider)

      assert station.name == "Teststadt Hbf"
      assert station.id.provider == TestRailProvider

      assert {:ok, [snapshot]} = Rail.list_api_snapshots(scope, claim.id)
      assert snapshot.payload == nil
      assert snapshot.provider == inspect(TestRailProvider)
      assert snapshot.operation == "search_stations"
      assert DateTime.compare(snapshot.fetched_at, ~U[2026-04-15 05:55:00Z]) == :eq
      assert snapshot.sha256 == :crypto.hash(:sha256, "<stations fixture='synthetic'/>")

      assert {:ok, [candidate]} =
               Rail.search_connections(
                 scope,
                 claim.id,
                 %{
                   origin: station.id,
                   destination: %{provider: TestRailProvider, value: "9999998"},
                   departure_at: ~U[2026-04-15 06:00:00Z]
                 },
                 provider: TestRailProvider
               )

      assert candidate.segments |> hd() |> Map.fetch!(:origin_name) == "Teststadt Hbf"

      assert {:error, :unsupported} =
               Rail.search_connections(scope, claim.id, %{},
                 provider: TestRailProvider,
                 result: {:error, :unsupported}
               )

      assert {:error, :timeout} =
               Rail.search_connections(scope, claim.id, %{},
                 provider: TestRailProvider,
                 result: {:error, :timeout}
               )

      assert {:error, :rate_limited} =
               Rail.search_connections(scope, claim.id, %{},
                 provider: TestRailProvider,
                 result: {:error, :rate_limited}
               )
    end

    test "does not disclose searches or snapshots across scopes" do
      owner_scope = scope_fixture()
      foreign_scope = scope_fixture()
      claim = claim_fixture(owner_scope)

      assert {:ok, _stations} =
               Rail.search_stations(owner_scope, claim.id, "Teststadt",
                 provider: TestRailProvider
               )

      assert {:error, :not_found} =
               Rail.search_stations(foreign_scope, claim.id, "Teststadt",
                 provider: TestRailProvider
               )

      assert {:error, :not_found} = Rail.list_api_snapshots(foreign_scope, claim.id)
    end
  end

  describe "confirmed journeys and derivations" do
    test "supports the complete manual fallback without provider metadata" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:ok, %{journey: journey, claim: updated_claim}} =
               Rail.confirm_journey(
                 scope,
                 claim.id,
                 :planned,
                 [
                   %{
                     origin_name: "Berlin Hbf",
                     destination_name: "Hamburg Hbf",
                     train_category: "ICE",
                     train_number: "100",
                     scheduled_departure: ~U[2026-07-15 06:00:00Z],
                     scheduled_arrival: ~U[2026-07-15 08:00:00Z]
                   }
                 ],
                 claim.lock_version
               )

      segment = hd(journey.segments)
      assert segment.manual
      assert segment.source == "manual"
      assert segment.fetched_at
      assert updated_claim.lock_version == claim.lock_version + 1

      assert {:error, :stale} =
               Rail.confirm_journey(
                 scope,
                 claim.id,
                 :actual,
                 [segment_attributes()],
                 claim.lock_version
               )
    end

    test "derives direct-delay values for C05" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      planned = segment_attributes(%{actual_departure: nil, actual_arrival: nil})
      actual = segment_attributes()

      journey_fixture(scope, claim, :planned, [planned])
      journey_fixture(scope, claim, :actual, [actual])

      assert {:ok, summary} = Rail.travel_summary(scope, claim.id)
      assert summary.first_disrupted_segment.position == 1
      assert summary.last_used_segment.position == 1
      assert summary.missed_connection_segment == nil

      assert DateTime.compare(summary.actual_destination_arrival, ~U[2026-07-15 08:30:00Z]) ==
               :eq

      assert {:ok, values} = Rail.form_values(scope, claim.id)
      assert values.first_disrupted_train.train_number == "100"
      assert values.last_used_train.destination == "Hamburg Hbf"

      assert DateTime.compare(values.actual_destination_arrival, ~U[2026-07-15 08:30:00Z]) ==
               :eq
    end

    test "derives a delayed feeder, missed connection and last replacement segment" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      planned = [
        segment_attributes(%{
          destination_name: "Hannover Hbf",
          scheduled_arrival: ~U[2026-07-15 08:00:00Z],
          actual_departure: nil,
          actual_arrival: nil
        }),
        segment_attributes(%{
          origin_name: "Hannover Hbf",
          train_number: "200",
          scheduled_departure: ~U[2026-07-15 08:15:00Z],
          scheduled_arrival: ~U[2026-07-15 10:00:00Z],
          actual_departure: nil,
          actual_arrival: nil
        })
      ]

      actual = [
        segment_attributes(%{
          destination_name: "Hannover Hbf",
          scheduled_arrival: ~U[2026-07-15 08:00:00Z],
          actual_arrival: ~U[2026-07-15 08:30:00Z]
        }),
        segment_attributes(%{
          origin_name: "Hannover Hbf",
          train_category: "IC",
          train_number: "202",
          scheduled_departure: ~U[2026-07-15 08:15:00Z],
          scheduled_arrival: ~U[2026-07-15 10:00:00Z],
          actual_departure: ~U[2026-07-15 08:45:00Z],
          actual_arrival: ~U[2026-07-15 10:40:00Z],
          manual: true,
          source: "manual"
        })
      ]

      journey_fixture(scope, claim, :planned, planned)
      journey_fixture(scope, claim, :actual, actual)

      assert {:ok, summary} = Rail.travel_summary(scope, claim.id)
      assert summary.first_disrupted_segment.position == 1
      assert summary.missed_connection_segment.position == 2
      assert summary.last_used_segment.train_number == "202"

      assert DateTime.compare(summary.actual_destination_arrival, ~U[2026-07-15 10:40:00Z]) ==
               :eq
    end

    test "derives cancellation and replacement journey values" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      journey_fixture(scope, claim, :planned, [
        segment_attributes(%{actual_departure: nil, actual_arrival: nil})
      ])

      journey_fixture(scope, claim, :actual, [
        segment_attributes(%{cancelled: true, actual_departure: nil, actual_arrival: nil}),
        segment_attributes(%{
          train_category: "IC",
          train_number: "900",
          scheduled_departure: ~U[2026-07-15 07:00:00Z],
          scheduled_arrival: ~U[2026-07-15 09:00:00Z],
          actual_departure: ~U[2026-07-15 07:00:00Z],
          actual_arrival: ~U[2026-07-15 09:20:00Z],
          source: "manual",
          manual: true
        })
      ])

      assert {:ok, summary} = Rail.travel_summary(scope, claim.id)
      assert summary.first_disrupted_segment.cancelled
      assert summary.last_used_segment.train_number == "900"

      assert DateTime.compare(summary.actual_destination_arrival, ~U[2026-07-15 09:20:00Z]) ==
               :eq
    end

    test "allows explicit summary overrides" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      journey_fixture(scope, claim, :planned)

      actual =
        journey_fixture(scope, claim, :actual, [
          segment_attributes(),
          segment_attributes(%{
            train_number: "200",
            scheduled_departure: ~U[2026-07-15 09:00:00Z],
            scheduled_arrival: ~U[2026-07-15 10:00:00Z],
            actual_departure: ~U[2026-07-15 09:00:00Z],
            actual_arrival: ~U[2026-07-15 10:10:00Z]
          })
        ])

      second = Enum.at(actual.segments, 1)
      {:ok, claim} = Claims.get_claim(scope, claim.id)

      assert {:ok, %{journey: overridden, claim: claim}} =
               Rail.set_summary_overrides(
                 scope,
                 claim.id,
                 %{
                   first_disrupted_segment_id: second.id,
                   actual_destination_arrival: ~U[2026-07-15 11:00:00Z]
                 },
                 claim.lock_version
               )

      assert overridden.first_disrupted_segment_id == second.id
      assert {:ok, summary} = Rail.travel_summary(scope, claim.id)
      assert summary.first_disrupted_segment.id == second.id

      assert DateTime.compare(summary.actual_destination_arrival, ~U[2026-07-15 11:00:00Z]) ==
               :eq

      assert {:error, :invalid_override} =
               Rail.set_summary_overrides(
                 scope,
                 claim.id,
                 %{last_used_segment_id: Ecto.UUID.generate()},
                 claim.lock_version
               )
    end
  end

  describe "outcome-aware export readiness" do
    test "does not require an actual journey when the trip was not started" do
      scope = scope_fixture()

      claim =
        claim_fixture(scope, %{
          "journey_outcome" => "not_started",
          "disruption_cause" => "cancellation"
        })

      journey_fixture(scope, claim, :planned, [
        segment_attributes(%{actual_departure: nil, actual_arrival: nil})
      ])

      assert {:ok, values} = Rail.form_values(scope, claim.id)
      assert values.first_disrupted_train == nil
      assert values.last_used_train == nil
      assert values.actual_destination_arrival == nil
    end

    test "reports every missing actual fact for a delayed arrival" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      journey_fixture(scope, claim, :planned, [
        segment_attributes(%{actual_departure: nil, actual_arrival: nil})
      ])

      assert {:error, %{type: :incomplete, errors: errors}} =
               Rail.form_values(scope, claim.id)

      assert Enum.map(errors, & &1.field) == [
               :actual_segments,
               :first_disrupted_segment,
               :last_used_segment,
               :actual_destination_arrival
             ]
    end

    test "omits destination arrival fields after an aborted journey" do
      scope = scope_fixture()
      claim = claim_fixture(scope, %{"journey_outcome" => "aborted"})
      journey_fixture(scope, claim, :planned)
      journey_fixture(scope, claim, :actual)

      assert {:ok, values} = Rail.form_values(scope, claim.id)
      assert values.first_disrupted_train
      assert values.last_used_train
      assert values.actual_destination_arrival == nil
    end

    test "accepts explicit other-transport arrival without a last used train" do
      scope = scope_fixture()

      claim =
        claim_fixture(scope, %{
          "journey_outcome" => "continued_with_other_transport",
          "disruption_cause" => "cancellation"
        })

      journey_fixture(scope, claim, :planned)

      journey_fixture(scope, claim, :actual, [
        segment_attributes(%{
          cancelled: true,
          actual_departure: nil,
          actual_arrival: nil,
          estimated_departure: nil,
          estimated_arrival: nil
        })
      ])

      assert {:error, %{type: :incomplete, errors: [error]}} =
               Rail.form_values(scope, claim.id)

      assert error.field == :actual_destination_arrival
      {:ok, claim} = Claims.get_claim(scope, claim.id)

      assert {:ok, _result} =
               Rail.set_summary_overrides(
                 scope,
                 claim.id,
                 %{actual_destination_arrival: ~U[2026-07-15 09:15:00Z]},
                 claim.lock_version
               )

      assert {:ok, values} = Rail.form_values(scope, claim.id)
      assert values.last_used_train == nil
      assert values.actual_destination_arrival.time_zone == "Europe/Berlin"

      assert {values.actual_destination_arrival.hour, values.actual_destination_arrival.minute} ==
               {11, 15}
    end

    test "requires a derived or confirmed missed connection for that cause" do
      scope = scope_fixture()
      claim = claim_fixture(scope, %{"disruption_cause" => "missed_connection"})
      journey_fixture(scope, claim, :planned)
      journey_fixture(scope, claim, :actual)

      assert {:error, %{type: :incomplete, errors: errors}} =
               Rail.form_values(scope, claim.id)

      assert %{source: :rail, field: :missed_connection_segment, code: :required} in errors

      journey_fixture(scope, claim, :actual, [
        segment_attributes(%{
          destination_name: "Hannover Hbf",
          scheduled_arrival: ~U[2026-07-15 08:00:00Z],
          actual_arrival: ~U[2026-07-15 08:30:00Z]
        }),
        segment_attributes(%{
          origin_name: "Hannover Hbf",
          train_number: "200",
          scheduled_departure: ~U[2026-07-15 08:15:00Z],
          scheduled_arrival: ~U[2026-07-15 10:00:00Z],
          actual_departure: ~U[2026-07-15 08:45:00Z],
          actual_arrival: ~U[2026-07-15 10:30:00Z]
        })
      ])

      assert {:ok, values} = Rail.form_values(scope, claim.id)
      assert values.missed_connection.train_number == "200"
    end
  end

  describe "manual priority, lifecycle and scoping" do
    test "validates field lengths for manual segment updates" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      journey = journey_fixture(scope, claim, :actual)
      segment = hd(journey.segments)
      {:ok, claim} = Claims.get_claim(scope, claim.id)

      assert {:error, changeset} =
               Rail.update_segment(
                 scope,
                 segment.id,
                 %{origin_name: String.duplicate("x", 201)},
                 claim.lock_version
               )

      assert "should be at most 200 character(s)" in errors_on(changeset).origin_name
    end

    test "refresh never overwrites a manually edited segment" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      actual = journey_fixture(scope, claim, :actual)
      segment = hd(actual.segments)
      {:ok, claim} = Claims.get_claim(scope, claim.id)

      assert {:ok, %{segment: manual, claim: claim}} =
               Rail.update_segment(
                 scope,
                 segment.id,
                 %{destination_name: "Manuelles Ziel", actual_arrival: ~U[2026-07-15 09:00:00Z]},
                 claim.lock_version
               )

      assert manual.manual
      assert manual.source == "manual"

      assert {:ok, %{journey: overridden, claim: claim}} =
               Rail.set_summary_overrides(
                 scope,
                 claim.id,
                 %{
                   first_disrupted_segment_id: manual.id,
                   actual_destination_arrival: ~U[2026-07-15 10:00:00Z]
                 },
                 claim.lock_version
               )

      assert overridden.first_disrupted_segment_id == manual.id

      assert {:ok, %{journey: refreshed}} =
               Rail.refresh_journey(
                 scope,
                 claim.id,
                 :actual,
                 [segment_attributes(%{destination_name: "API-Ziel"})],
                 claim.lock_version
               )

      refreshed_segment = hd(refreshed.segments)
      assert refreshed_segment.destination_name == "Manuelles Ziel"
      assert DateTime.compare(refreshed_segment.actual_arrival, ~U[2026-07-15 09:00:00Z]) == :eq
      assert refreshed_segment.manual
      assert refreshed.first_disrupted_segment_id == manual.id

      assert DateTime.compare(
               refreshed.actual_destination_arrival,
               ~U[2026-07-15 10:00:00Z]
             ) == :eq
    end

    test "travel changes invalidate ready output and enforce optimistic locking" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      actual = journey_fixture(scope, claim, :actual)
      segment = hd(actual.segments)
      {:ok, claim} = Claims.get_claim(scope, claim.id)
      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)

      assert {:error, :stale} =
               Rail.update_segment(scope, segment.id, %{train_number: "999"}, claim.lock_version)

      assert {:ok, %{claim: draft}} =
               Rail.update_segment(scope, segment.id, %{train_number: "999"}, ready.lock_version)

      assert draft.status == :draft
      assert draft.generated_at == nil
    end

    test "user A cannot read or change user B's journeys" do
      owner_scope = scope_fixture()
      foreign_scope = scope_fixture()
      claim = claim_fixture(owner_scope)
      journey = journey_fixture(owner_scope, claim, :actual)
      segment = hd(journey.segments)

      assert {:error, :not_found} = Rail.get_journey(foreign_scope, claim.id, :actual)

      assert {:error, :not_found} =
               Rail.update_segment(
                 foreign_scope,
                 segment.id,
                 %{train_number: "stolen"},
                 claim.lock_version
               )

      assert {:error, :not_authenticated} = Rail.get_journey(nil, claim.id, :actual)
    end
  end
end
