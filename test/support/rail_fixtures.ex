defmodule Fahrgastrechte.RailFixtures do
  @moduledoc false

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Rail

  def segment_attributes(attrs \\ %{}) do
    Map.merge(
      %{
        origin_name: "Berlin Hbf",
        destination_name: "Hamburg Hbf",
        train_category: "ICE",
        train_number: "100",
        scheduled_departure: ~U[2026-07-15 06:00:00Z],
        scheduled_arrival: ~U[2026-07-15 08:00:00Z],
        actual_departure: ~U[2026-07-15 06:05:00Z],
        actual_arrival: ~U[2026-07-15 08:30:00Z],
        cancelled: false,
        source: "Fahrgastrechte.TestRailProvider",
        source_metadata: %{"fixture" => true},
        fetched_at: ~U[2026-07-15 08:31:00Z],
        manual: false
      },
      attrs
    )
  end

  def journey_fixture(scope, claim, kind, segments \\ [segment_attributes()]) do
    {:ok, current_claim} = Claims.get_claim(scope, claim.id)

    {:ok, %{journey: journey}} =
      Rail.confirm_journey(scope, claim.id, kind, segments, current_claim.lock_version)

    journey
  end
end
