defmodule Fahrgastrechte.ClaimsFixtures do
  @moduledoc false

  alias Fahrgastrechte.Claims

  import Fahrgastrechte.AccountsFixtures

  def valid_claim_attributes(attrs \\ %{}) do
    Map.merge(
      %{
        "travel_date" => ~D[2026-07-15],
        "origin" => "Berlin Hbf",
        "destination" => "Hamburg Hbf",
        "journey_outcome" => "delayed_arrival",
        "disruption_cause" => "delay",
        "journey_direction" => "outbound"
      },
      attrs
    )
  end

  def claim_fixture(scope \\ scope_fixture(), attrs \\ %{}) do
    {:ok, claim} = Claims.create_claim(scope, valid_claim_attributes(attrs))
    claim
  end
end
