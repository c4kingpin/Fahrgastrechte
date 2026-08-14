defmodule Fahrgastrechte.TestStationProvider do
  @behaviour Fahrgastrechte.Rail.Provider

  @impl true
  def search_stations(query, _options) do
    stations =
      case query do
        "Hannover" ->
          [station("8003487", "Hannover-Linden/Fischerhof"), station("8000152", "Hannover Hbf")]

        "Frankfurt(M) Flughafen" ->
          [
            station("8070003", "Frankfurt(M) Flughafen Regionalbf"),
            station("8070004", "Frankfurt(M) Flughafen Fernbf")
          ]

        _query ->
          []
      end

    {:ok, stations}
  end

  @impl true
  def search_connections(_query, _options), do: {:error, :unsupported}

  @impl true
  def departures(_station_id, _from, _until, _options), do: {:error, :not_found}

  @impl true
  def journey(_journey_id, _options), do: {:error, :not_found}

  defp station(eva, name) do
    %{id: %{provider: __MODULE__, value: eva}, name: name, eva_number: eva}
  end
end
