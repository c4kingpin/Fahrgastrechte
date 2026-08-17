defmodule Fahrgastrechte.Tickets.StationNormalizerTest do
  use ExUnit.Case, async: true

  alias Fahrgastrechte.Tickets.StationNormalizer

  test "selects canonical DB station names for City tickets and ICE airport routes" do
    suggestions = [
      suggestion(:origin, %{"text" => "Hannover+City"}),
      suggestion(:destination, %{"text" => "Frankfurt(M)Flugh. mit ICE"})
    ]

    search_stations = fn
      "Hannover" ->
        {:ok,
         [
           %{name: "Hannover-Linden/Fischerhof"},
           %{name: "Hannover Hbf"}
         ]}

      "Frankfurt(M) Flughafen" ->
        {:ok,
         [
           %{name: "Frankfurt(M) Flughafen Regionalbf"},
           %{name: "Frankfurt(M) Flughafen Fernbf"}
         ]}

      _query ->
        {:ok, []}
    end

    normalized = StationNormalizer.normalize(suggestions, search_stations)

    assert Enum.at(normalized, 0).value == %{
             "text" => "Hannover Hbf",
             "candidates" => [
               %{"text" => "Hannover Hbf", "station_id" => nil},
               %{"text" => "Hannover-Linden/Fischerhof", "station_id" => nil}
             ]
           }

    assert Enum.at(normalized, 1).value == %{
             "text" => "Frankfurt(M) Flughafen Fernbf",
             "candidates" => [
               %{"text" => "Frankfurt(M) Flughafen Fernbf", "station_id" => nil},
               %{"text" => "Frankfurt(M) Flughafen Regionalbf", "station_id" => nil}
             ]
           }

    refute Map.has_key?(Enum.at(normalized, 0).value, "unresolved")
    refute Map.has_key?(Enum.at(normalized, 1).value, "unresolved")
  end

  test "merges candidates found across different search query variants" do
    suggestion = suggestion(:destination, %{"text" => "Frankfurt(M)Flugh."})

    search_stations = fn
      "Frankfurt(M) Flughafen" -> {:ok, [%{name: "Frankfurt(M) Flughafen Fernbf"}]}
      "Frankfurt(M)Flugh." -> {:ok, [%{name: "Frankfurt(M) Flughafen Regionalbf"}]}
      _query -> {:ok, []}
    end

    [normalized] = StationNormalizer.normalize([suggestion], search_stations)

    assert normalized.value["candidates"] == [
             %{"text" => "Frankfurt(M) Flughafen Fernbf", "station_id" => nil},
             %{"text" => "Frankfurt(M) Flughafen Regionalbf", "station_id" => nil}
           ]
  end

  test "normalizes station names embedded in scheduled times and caches repeated text" do
    parent = self()

    suggestions = [
      suggestion(:origin, %{"text" => "Berlin Hbf"}),
      suggestion(:scheduled_departure, %{"station" => "Berlin Hbf", "time" => "08:04"})
    ]

    normalized =
      StationNormalizer.normalize(suggestions, fn query ->
        send(parent, {:station_search, query})
        {:ok, [%{name: "Berlin Hbf"}]}
      end)

    assert Enum.at(normalized, 0).value == %{
             "text" => "Berlin Hbf",
             "candidates" => [%{"text" => "Berlin Hbf", "station_id" => nil}]
           }

    assert Enum.at(normalized, 1).value == %{
             "station" => "Berlin Hbf",
             "time" => "08:04"
           }

    assert_received {:station_search, "Berlin Hbf"}
    refute_received {:station_search, "Berlin Hbf"}
  end

  test "keeps extracted text but flags it unresolved when the provider is unavailable or has no plausible match" do
    suggestions = [suggestion(:origin, %{"text" => "Unklare Angabe"})]
    expected = flag_unresolved(suggestions)

    assert StationNormalizer.normalize(suggestions, fn _query ->
             {:error, {:upstream, :not_configured}}
           end) == expected

    assert StationNormalizer.normalize(suggestions, fn _query ->
             {:ok, [%{name: "Berlin Hbf"}]}
           end) == expected

    airport = [suggestion(:destination, %{"text" => "Frankfurt(M)Flugh. mit ICE"})]

    [normalized_airport] =
      StationNormalizer.normalize(airport, fn _query ->
        {:ok, [%{name: "Frankfurt(M) Flughafen Regionalbf"}]}
      end)

    assert normalized_airport.value == %{
             "text" => "Frankfurt(M)Flugh. mit ICE",
             "unresolved" => true,
             "candidates" => [
               %{"text" => "Frankfurt(M) Flughafen Regionalbf", "station_id" => nil}
             ]
           }
  end

  defp flag_unresolved(suggestions) do
    Enum.map(suggestions, fn suggestion ->
      %{suggestion | value: Map.put(suggestion.value, "unresolved", true)}
    end)
  end

  defp suggestion(field, value) do
    %{
      field: field,
      value: value,
      confidence: 0.95,
      source: %{page: 1, excerpt: inspect(value)}
    }
  end
end
