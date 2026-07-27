defmodule Fahrgastrechte.TestRailProvider do
  @behaviour Fahrgastrechte.Rail.Provider

  @impl true
  def search_stations(_query, options) do
    Keyword.get_lazy(options, :result, fn ->
      fetched_at = ~U[2026-04-15 05:55:00Z]

      {:ok,
       [
         %{
           id: %{provider: __MODULE__, value: "9999999"},
           name: "Teststadt Hbf",
           eva_number: "9999999"
         }
       ],
       %{
         payload: "<stations fixture='synthetic'/>",
         content_type: "application/xml",
         fetched_at: fetched_at,
         metadata: %{"fixture" => true}
       }}
    end)
  end

  @impl true
  def search_connections(_query, options) do
    Keyword.get(options, :result, {:ok, [journey()]})
  end

  @impl true
  def departures(_station_id, _from, _until, options) do
    Keyword.get(options, :result, {:ok, [journey()]})
  end

  @impl true
  def journey(_journey_id, options) do
    Keyword.get(options, :result, {:ok, journey()})
  end

  defp journey do
    %{
      id: %{provider: __MODULE__, value: "synthetic-journey"},
      category: "ICE",
      number: "100",
      fetched_at: ~U[2026-04-15 05:55:00Z],
      events: [
        %{
          station: %{
            id: %{provider: __MODULE__, value: "9999999"},
            name: "Teststadt Hbf"
          },
          scheduled_at: ~U[2026-04-15 06:04:00Z],
          estimated_at: ~U[2026-04-15 06:19:00Z]
        },
        %{
          station: %{
            id: %{provider: __MODULE__, value: "9999998"},
            name: "Beispielstadt Hbf"
          },
          scheduled_at: ~U[2026-04-15 10:10:00Z],
          estimated_at: ~U[2026-04-15 10:42:00Z]
        }
      ]
    }
  end
end
