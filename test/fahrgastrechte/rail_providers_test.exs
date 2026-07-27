defmodule Fahrgastrechte.RailProvidersTest do
  use ExUnit.Case, async: true

  alias Fahrgastrechte.Rail.Providers.BahnVorhersageArchive
  alias Fahrgastrechte.Rail.Providers.Timetables

  @fixtures Path.expand("../fixtures/c00", __DIR__)

  describe "Timetables" do
    test "normalizes station XML and retains a raw snapshot without live network" do
      station_xml = File.read!(Path.join(@fixtures, "timetables-station.xml"))
      parent = self()

      request_fun = fn options ->
        send(parent, {:request, options})

        {:ok,
         %{status: 200, body: station_xml, headers: %{"content-type" => ["application/xml"]}}}
      end

      assert {:ok, [station], snapshot} =
               Timetables.search_stations("Teststadt Hbf",
                 client_id: "synthetic-client",
                 api_key: "synthetic-key",
                 limiter: false,
                 request_fun: request_fun
               )

      assert station.name == "Teststadt Hbf"
      assert station.eva_number == "9999999"
      assert station.id == %{provider: Timetables, value: "9999999"}
      assert snapshot.payload == station_xml
      assert snapshot.content_type == "application/xml"

      assert_receive {:request, options}
      assert String.ends_with?(options[:url], "/station/Teststadt%20Hbf")
      assert {"DB-Client-Id", "synthetic-client"} in options[:headers]
      assert {"DB-Api-Key", "synthetic-key"} in options[:headers]
    end

    test "correlates plan and cancellation changes for departure reconstruction" do
      plan_xml = File.read!(Path.join(@fixtures, "timetables-plan.xml"))
      cancellation_xml = File.read!(Path.join(@fixtures, "timetables-cancellation.xml"))

      request_fun = fn options ->
        body = if String.contains?(options[:url], "/plan/"), do: plan_xml, else: cancellation_xml
        {:ok, %{status: 200, body: body, headers: %{}}}
      end

      assert {:ok, [journey], snapshots} =
               Timetables.departures(
                 %{provider: Timetables, value: "9999999"},
                 ~U[2026-04-15 06:00:00Z],
                 ~U[2026-04-15 07:00:00Z],
                 client_id: "synthetic-client",
                 api_key: "synthetic-key",
                 limiter: false,
                 request_fun: request_fun
               )

      assert journey.category == "ICE"
      assert journey.number == "100"
      assert journey.id.value == "-123456789-2604150804-1"
      assert hd(journey.events).scheduled_at == ~U[2026-04-15 06:04:00Z]
      assert hd(journey.events).cancelled
      assert List.last(journey.events).station.name == "Beispielstadt Hbf"
      assert length(snapshots) == 2
    end

    test "normalizes timeout, rate limit and unavailable credentials" do
      assert {:error, {:upstream, :not_configured}} = Timetables.search_stations("Berlin", [])

      assert {:error, :rate_limited} =
               Timetables.search_stations("Berlin",
                 client_id: "client",
                 api_key: "key",
                 limiter: false,
                 sleep_fun: fn _milliseconds -> :ok end,
                 request_fun: fn _options -> {:ok, %{status: 429, body: "", headers: %{}}} end
               )

      assert {:error, :timeout} =
               Timetables.search_stations("Berlin",
                 client_id: "client",
                 api_key: "key",
                 limiter: false,
                 sleep_fun: fn _milliseconds -> :ok end,
                 request_fun: fn _options -> {:error, %{reason: :timeout}} end
               )

      assert {:error, {:upstream, :response_too_large}} =
               Timetables.search_stations("Berlin",
                 client_id: "client",
                 api_key: "key",
                 limiter: false,
                 max_response_bytes: 4,
                 request_fun: fn _options ->
                   {:ok, %{status: 200, body: "12345", headers: %{}}}
                 end
               )
    end

    test "limits and retries every HTTP attempt while honoring Retry-After" do
      parent = self()

      request_fun = fn _options ->
        send(parent, :attempt)
        {:ok, %{status: 429, body: "", headers: %{"retry-after" => ["2"]}}}
      end

      assert {:error, :rate_limited} =
               Timetables.search_stations("Berlin",
                 client_id: "client",
                 api_key: "key",
                 limiter: false,
                 request_fun: request_fun,
                 sleep_fun: fn milliseconds -> send(parent, {:retry_delay, milliseconds}) end
               )

      assert_receive :attempt
      assert_receive {:retry_delay, 2_000}
      assert_receive :attempt
      assert_receive {:retry_delay, 2_000}
      assert_receive :attempt
      refute_receive :attempt
    end

    test "rejects XML entity declarations" do
      assert {:error, {:upstream, :invalid_response}} =
               Timetables.search_stations("Berlin",
                 client_id: "client",
                 api_key: "key",
                 limiter: false,
                 request_fun: fn _options ->
                   {:ok,
                    %{
                      status: 200,
                      body: "<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><x/>",
                      headers: %{}
                    }}
                 end
               )
    end
  end

  describe "BahnVorhersageArchive" do
    test "uses final observations as actual values and preserves attribution" do
      data_path = Path.join(@fixtures, "bahnvorhersage-parsed-delays.csv")

      options = [
        data_path: data_path,
        dataset_version: "synthetic-2026",
        station_names: %{
          "9999999" => "Teststadt Hbf",
          "9999998" => "Beispielstadt Hbf"
        }
      ]

      assert {:ok, [journey]} =
               BahnVorhersageArchive.departures(
                 %{provider: BahnVorhersageArchive, value: "9999999"},
                 ~U[2026-04-15 08:00:00Z],
                 ~U[2026-04-15 09:00:00Z],
                 options
               )

      first = hd(journey.events)
      last = List.last(journey.events)
      assert first.actual_at == ~U[2026-04-15 08:17:00Z]
      assert first.estimated_at == nil
      assert last.actual_at == ~U[2026-04-15 13:24:00Z]
      assert last.station.name == "Beispielstadt Hbf"
      assert journey.source_metadata["dataset_version"] == "synthetic-2026"
      assert journey.source_metadata["license"] == "ODbL-1.0"
      assert is_binary(journey.source_metadata["source_sha256"])
    end

    test "returns manual fallback when the archive or date is missing" do
      station_id = %{provider: BahnVorhersageArchive, value: "9999999"}

      assert {:error, :history_unavailable} =
               BahnVorhersageArchive.departures(
                 station_id,
                 ~U[2026-04-15 08:00:00Z],
                 ~U[2026-04-15 09:00:00Z],
                 data_path: "/not/present.csv"
               )

      assert {:error, :history_unavailable} =
               BahnVorhersageArchive.departures(
                 station_id,
                 ~U[2025-04-15 08:00:00Z],
                 ~U[2025-04-15 09:00:00Z],
                 data_path: Path.join(@fixtures, "bahnvorhersage-parsed-delays.csv")
               )
    end
  end
end
