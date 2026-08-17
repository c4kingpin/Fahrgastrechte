defmodule Fahrgastrechte.Rail.Providers.StationCatalog do
  @moduledoc """
  Searches the locally imported OpenStation catalog (`Fahrgastrechte.Rail.Station`).

  Unlike the live Timetables `/station/{pattern}` lookup, which returns at
  most one arbitrary match, this provider searches the complete, periodically
  synced station list (`Fahrgastrechte.Rail.StationCatalogSync`), so sibling
  stations at the same place (Hbf, Fernbahnhof, Regionalbahnhof, ...) are
  reliably found instead of guessed at. It only answers station lookups;
  connections/departures/journeys stay on `Providers.Timetables`.
  """

  @behaviour Fahrgastrechte.Rail.Provider

  import Ecto.Query

  alias Fahrgastrechte.Rail.Station
  alias Fahrgastrechte.Repo

  @result_limit 50

  @impl true
  def search_stations(query, _options) do
    normalized = query |> to_string() |> String.trim()
    tokens = tokenize(normalized)

    if tokens == [] do
      {:ok, []}
    else
      stations =
        Station
        |> where(^token_conditions(tokens))
        |> order_by([s], asc: s.name)
        |> limit(^@result_limit)
        |> Repo.all()
        |> Enum.sort_by(&relevance_rank(&1.name, normalized))
        |> Enum.map(&to_provider_station/1)

      {:ok, stations}
    end
  end

  @impl true
  def search_connections(_query, _options), do: {:error, :unsupported}

  @impl true
  def departures(_station_id, _from, _until, _options), do: {:error, :not_found}

  @impl true
  def journey(_journey_id, _options), do: {:error, :not_found}

  # Word-level AND instead of one literal phrase substring: the official
  # OpenStation catalog punctuates/spells places differently than ticket text
  # does (e.g. catalog "Frankfurt (Main) Flughafen Regionalbahnhof" /
  # "Frankfurt am Main Flughafen Fernbahnhof" vs. ticket text
  # "Frankfurt(M)Flugh."), so requiring the whole phrase as one substring
  # missed real stations. Requiring each query word separately still finds
  # them; StationNormalizer's scoring (which already tolerates these
  # spelling differences) picks the right one out of the wider result set.
  defp tokenize(text), do: text |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

  defp token_conditions(tokens) do
    Enum.reduce(tokens, dynamic(true), fn token, acc ->
      pattern = "%" <> escape_like(token) <> "%"
      dynamic([s], ^acc and ilike(s.name, ^pattern))
    end)
  end

  # Exact match first, then prefix matches, then everything else — the
  # manual "Anderen Bahnhof suchen" search box takes this order as-is
  # (`ClaimWorkspace.station_search_options/3`), it does not re-score.
  defp relevance_rank(name, query) do
    downcased_name = String.downcase(name)
    downcased_query = String.downcase(query)

    cond do
      downcased_name == downcased_query -> 0
      String.starts_with?(downcased_name, downcased_query) -> 1
      true -> 2
    end
  end

  defp to_provider_station(%Station{} = station) do
    %{
      id: %{provider: __MODULE__, value: station.eva_number},
      name: station.name,
      eva_number: station.eva_number
    }
  end

  defp escape_like(value), do: Regex.replace(~r/[\\%_]/, value, &("\\" <> &1))
end
