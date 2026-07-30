defmodule Fahrgastrechte.BerlinTimeTest do
  use ExUnit.Case, async: true

  alias Fahrgastrechte.Rail.BerlinTime

  test "converts winter and summer UTC instants to Europe/Berlin" do
    winter = BerlinTime.to_local(~U[2026-01-15 07:04:00Z])
    summer = BerlinTime.to_local(~U[2026-07-15 06:04:00Z])

    assert winter.time_zone == "Europe/Berlin"
    assert winter.zone_abbr == "CET"
    assert {winter.hour, winter.minute} == {8, 4}
    assert DateTime.compare(winter, ~U[2026-01-15 07:04:00Z]) == :eq

    assert summer.time_zone == "Europe/Berlin"
    assert summer.zone_abbr == "CEST"
    assert {summer.hour, summer.minute} == {8, 4}
    assert DateTime.compare(summer, ~U[2026-07-15 06:04:00Z]) == :eq
  end

  test "converts unambiguous local railway input back to UTC" do
    assert {:ok, winter} = BerlinTime.from_local(~N[2026-01-15 08:04:00])
    assert {:ok, summer} = BerlinTime.from_local(~N[2026-07-15 08:04:00])

    assert DateTime.compare(winter, ~U[2026-01-15 07:04:00Z]) == :eq
    assert DateTime.compare(summer, ~U[2026-07-15 06:04:00Z]) == :eq
  end

  test "rejects nonexistent and ambiguous daylight-saving input" do
    assert {:error, :nonexistent_local_time} =
             BerlinTime.from_local(~N[2026-03-29 02:30:00])

    assert {:error, :ambiguous_local_time} =
             BerlinTime.from_local(~N[2026-10-25 02:30:00])
  end
end
