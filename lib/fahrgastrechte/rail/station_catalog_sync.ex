defmodule Fahrgastrechte.Rail.StationCatalogSync do
  @moduledoc """
  Crawls the OpenStation catalog and upserts it into the local `stations` table.

  OpenStation exposes no name search, only a paginated full export
  (`Fahrgastrechte.Rail.Providers.OpenStation.fetch_page/2`). This module
  walks every page and keeps the local catalog current so
  `Fahrgastrechte.Rail.Providers.StationCatalog` can answer suggestions from
  a complete, real dataset instead of a single upstream "best guess".
  """

  alias Fahrgastrechte.Rail.Providers.OpenStation
  alias Fahrgastrechte.Rail.Station
  alias Fahrgastrechte.Repo

  # The real catalog is ~57 pages at the API's page-size cap of 100; this is a
  # generous ceiling against an unexpected pagination loop, not a real limit.
  @max_pages 200

  @doc """
  Runs a full crawl and upsert.

  Returns `{:ok, %{pages:, stations:}}` once the API reports no further page,
  or `{:error, {reason, %{pages:, stations:}}}` if a page fetch fails midway —
  whatever was already upserted before the failure stays in place, and the
  next scheduled run picks up where this one left off.
  """
  @spec run(keyword()) ::
          {:ok, %{pages: non_neg_integer(), stations: non_neg_integer()}}
          | {:error, {term(), %{pages: non_neg_integer(), stations: non_neg_integer()}}}
  def run(options \\ []) do
    fetch_page = Keyword.get(options, :fetch_page, &OpenStation.fetch_page/2)
    crawl(fetch_page, options, 1, %{pages: 0, stations: 0})
  end

  defp crawl(_fetch_page, _options, page, acc) when page > @max_pages do
    {:error, {{:page_limit_exceeded, @max_pages}, acc}}
  end

  defp crawl(fetch_page, options, page, acc) do
    case fetch_page.(page, options) do
      {:ok, stations, has_next?} ->
        acc = %{pages: acc.pages + 1, stations: acc.stations + upsert(stations)}

        if has_next? do
          crawl(fetch_page, options, page + 1, acc)
        else
          {:ok, acc}
        end

      {:error, reason} ->
        {:error, {reason, acc}}
    end
  end

  defp upsert([]), do: 0

  defp upsert(stations) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    rows = Enum.map(stations, &row(&1, now))

    {count, _result} =
      Repo.insert_all(Station, rows,
        on_conflict:
          {:replace, [:name, :dhid, :stop_place_type, :transport_mode, :synced_at, :updated_at]},
        conflict_target: :eva_number
      )

    count
  end

  defp row(station, now) do
    %{
      id: Ecto.UUID.generate(),
      name: station.name,
      eva_number: station.eva_number,
      dhid: Map.get(station, :dhid),
      stop_place_type: Map.get(station, :stop_place_type),
      transport_mode: Map.get(station, :transport_mode),
      source_metadata: %{},
      synced_at: now,
      inserted_at: now,
      updated_at: now
    }
  end
end
