defmodule Fahrgastrechte.Rail.StationCatalogSyncTest do
  use Fahrgastrechte.DataCase, async: true

  alias Fahrgastrechte.Rail.Station
  alias Fahrgastrechte.Rail.StationCatalogSync

  describe "run/1" do
    test "crawls every page until has_next? is false and upserts each station" do
      pages = %{
        1 => {:ok, [station("Hannover Hbf", "8000152")], true},
        2 => {:ok, [station("Frankfurt(M) Flughafen Regionalbf", "8070004")], false}
      }

      fetch_page = fn page, _options -> Map.fetch!(pages, page) end

      assert {:ok, %{pages: 2, stations: 2}} = StationCatalogSync.run(fetch_page: fetch_page)

      names = Station |> Repo.all() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Frankfurt(M) Flughafen Regionalbf", "Hannover Hbf"]
    end

    test "updates an existing row instead of duplicating it when the EVA number recurs" do
      fetch_page = fn 1, _options ->
        {:ok, [station("Hannover Anderten-Misburg", "8000578")], false}
      end

      assert {:ok, %{stations: 1}} = StationCatalogSync.run(fetch_page: fetch_page)

      renamed_fetch_page = fn 1, _options ->
        {:ok, [station("Hannover Anderten-Misburg (neu)", "8000578")], false}
      end

      assert {:ok, %{stations: 1}} = StationCatalogSync.run(fetch_page: renamed_fetch_page)

      assert [%Station{name: "Hannover Anderten-Misburg (neu)", eva_number: "8000578"}] =
               Repo.all(Station)
    end

    test "stops at the first failing page, keeping already-upserted rows and reporting how far it got" do
      pages = %{1 => {:ok, [station("Hannover Hbf", "8000152")], true}}

      fetch_page = fn
        1, _options -> Map.fetch!(pages, 1)
        2, _options -> {:error, {:upstream, 500}}
      end

      assert {:error, {{:upstream, 500}, %{pages: 1, stations: 1}}} =
               StationCatalogSync.run(fetch_page: fetch_page)

      assert [%Station{name: "Hannover Hbf"}] = Repo.all(Station)
    end
  end

  defp station(name, eva_number) do
    %{
      name: name,
      eva_number: eva_number,
      dhid: "dhid:#{eva_number}",
      stop_place_type: "railStation",
      transport_mode: "rail"
    }
  end
end
