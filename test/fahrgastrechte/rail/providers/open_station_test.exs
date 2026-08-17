defmodule Fahrgastrechte.Rail.Providers.OpenStationTest do
  use ExUnit.Case, async: true

  alias Fahrgastrechte.Rail.Providers.OpenStation

  # A minimal but representative NeTEx page: a default (unprefixed) XML
  # namespace like the real API, one plain station, and one station whose
  # <Name> has mixed content (a direct text node plus a nested <Text> child
  # for an alternate-language name, as real border stations like Flensburg
  # do) to prove nested elements never leak into the extracted station name.
  # A nested equipment <Name> ("zu Gleis 1") also proves deep descendants
  # are never mistaken for the station's own name.
  @netex_page """
  <?xml version="1.0" encoding="UTF-8"?>
  <PublicationDelivery xmlns="http://www.netex.org.uk/netex">
    <dataObjects>
      <CompositeFrame>
        <frames>
          <SiteFrame>
            <stopPlaces>
              <StopPlace id="dhid:de:99999:900000001">
                <keyList>
                  <KeyValue><Key>EVA</Key><Value>8000105</Value></KeyValue>
                  <KeyValue><Key>RIL</Key><Value>FF</Value></KeyValue>
                </keyList>
                <Name lang="de">Teststadt Hbf</Name>
                <placeEquipments>
                  <LiftEquipment>
                    <Name lang="de">zu Gleis 1</Name>
                  </LiftEquipment>
                </placeEquipments>
                <TransportMode>rail</TransportMode>
                <StopPlaceType>railStation</StopPlaceType>
              </StopPlace>
              <StopPlace id="dhid:de:99999:900000002">
                <keyList>
                  <KeyValue><Key>EVA</Key><Value>8000200</Value></KeyValue>
                </keyList>
                <Name lang="de">Grenzstadt<Text lang="dan">Grenzeby</Text></Name>
                <TransportMode>rail</TransportMode>
                <StopPlaceType>railStation</StopPlaceType>
              </StopPlace>
              <StopPlace id="dhid:de:99999:900000004">
                <keyList>
                  <KeyValue><Key>EVA</Key><Value>8000237</Value></KeyValue>
                </keyList>
                <Name lang="de">Lübeck Hbf</Name>
                <TransportMode>rail</TransportMode>
                <StopPlaceType>railStation</StopPlaceType>
              </StopPlace>
              <StopPlace id="dhid:de:99999:900000003">
                <keyList>
                  <KeyValue><Key>RIL</Key><Value>NOEVA</Value></KeyValue>
                </keyList>
                <Name lang="de">Ohne EVA-Nummer</Name>
              </StopPlace>
            </stopPlaces>
          </SiteFrame>
        </frames>
      </CompositeFrame>
    </dataObjects>
  </PublicationDelivery>
  """

  test "parses stations from a NeTEx page, ignoring nested equipment/alt-language names" do
    parent = self()

    request_fun = fn options ->
      send(parent, {:request, options})
      {:ok, %{status: 200, body: @netex_page, headers: %{"link" => [~s(<...>; rel="next")]}}}
    end

    assert {:ok, stations, true} =
             OpenStation.fetch_page(1,
               client_id: "synthetic-client",
               api_key: "synthetic-key",
               request_fun: request_fun
             )

    assert stations == [
             %{
               name: "Teststadt Hbf",
               eva_number: "8000105",
               dhid: "dhid:de:99999:900000001",
               stop_place_type: "railStation",
               transport_mode: "rail"
             },
             %{
               name: "Grenzstadt",
               eva_number: "8000200",
               dhid: "dhid:de:99999:900000002",
               stop_place_type: "railStation",
               transport_mode: "rail"
             },
             %{
               name: "Lübeck Hbf",
               eva_number: "8000237",
               dhid: "dhid:de:99999:900000004",
               stop_place_type: "railStation",
               transport_mode: "rail"
             }
           ]

    assert_receive {:request, options}
    assert options[:url] |> String.ends_with?("/netex")
    assert options[:params][:page] == 1
    assert {"DB-Client-Id", "synthetic-client"} in options[:headers]
    assert {"DB-Api-Key", "synthetic-key"} in options[:headers]
  end

  test "reports no next page when the Link header has no rel=\"next\" entry" do
    request_fun = fn _options ->
      {:ok, %{status: 200, body: @netex_page, headers: %{"link" => [~s(<...>; rel="last")]}}}
    end

    assert {:ok, _stations, false} =
             OpenStation.fetch_page(57,
               client_id: "synthetic-client",
               api_key: "synthetic-key",
               request_fun: request_fun
             )
  end

  test "fails fast without credentials" do
    assert {:error, {:upstream, :not_configured}} =
             OpenStation.fetch_page(1,
               client_id: nil,
               api_key: nil,
               request_fun: fn _ -> flunk() end
             )
  end

  test "surfaces non-200 responses as upstream errors" do
    request_fun = fn _options -> {:ok, %{status: 429, body: "", headers: %{}}} end

    assert {:error, :rate_limited} =
             OpenStation.fetch_page(1,
               client_id: "synthetic-client",
               api_key: "synthetic-key",
               request_fun: request_fun
             )
  end
end
