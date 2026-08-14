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

    assert Enum.at(normalized, 0).value == %{"text" => "Hannover Hbf"}

    assert Enum.at(normalized, 1).value == %{
             "text" => "Frankfurt(M) Flughafen Fernbf"
           }
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

    assert Enum.at(normalized, 0).value == %{"text" => "Berlin Hbf"}

    assert Enum.at(normalized, 1).value == %{
             "station" => "Berlin Hbf",
             "time" => "08:04"
           }

    assert_received {:station_search, "Berlin Hbf"}
    refute_received {:station_search, "Berlin Hbf"}
  end

  test "keeps extracted text when the provider is unavailable or has no plausible match" do
    suggestions = [suggestion(:origin, %{"text" => "Unklare Angabe"})]

    assert StationNormalizer.normalize(suggestions, fn _query ->
             {:error, {:upstream, :not_configured}}
           end) == suggestions

    assert StationNormalizer.normalize(suggestions, fn _query ->
             {:ok, [%{name: "Berlin Hbf"}]}
           end) == suggestions

    airport = [suggestion(:destination, %{"text" => "Frankfurt(M)Flugh. mit ICE"})]

    assert StationNormalizer.normalize(airport, fn _query ->
             {:ok, [%{name: "Frankfurt(M) Flughafen Regionalbf"}]}
           end) == airport
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
