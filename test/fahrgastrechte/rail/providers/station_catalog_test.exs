defmodule Fahrgastrechte.Rail.Providers.StationCatalogTest do
  use Fahrgastrechte.DataCase, async: true

  alias Fahrgastrechte.Rail.Providers.StationCatalog
  alias Fahrgastrechte.Rail.Station

  setup do
    seed!("Hannover Hbf", "8000152")
    seed!("Hannover Anderten-Misburg", "8000578")
    seed!("Hannover-Linden/Fischerhof", "8003487")
    seed!("Frankfurt(M) Flughafen Regionalbf", "8070004")
    seed!("Frankfurt(M) Flughafen Fernbf", "8070003")
    :ok
  end

  describe "search_stations/2" do
    test "finds every station whose name contains the query, exact/prefix matches first" do
      assert {:ok, stations} = StationCatalog.search_stations("Hannover", [])
      names = Enum.map(stations, & &1.name)

      assert names == [
               "Hannover Anderten-Misburg",
               "Hannover Hbf",
               "Hannover-Linden/Fischerhof"
             ]
    end

    test "returns an exact match first even when a shorter alphabetical name would sort earlier" do
      assert {:ok, [%{name: "Hannover Hbf"} | _rest]} =
               StationCatalog.search_stations("Hannover Hbf", [])
    end

    test "finds sibling station types at the same place" do
      assert {:ok, stations} = StationCatalog.search_stations("Frankfurt(M) Flughafen", [])
      names = Enum.map(stations, & &1.name)

      assert "Frankfurt(M) Flughafen Regionalbf" in names
      assert "Frankfurt(M) Flughafen Fernbf" in names
    end

    test "finds stations whose official name differs from ticket-text abbreviations" do
      seed!("Frankfurt (Main) Flughafen Regionalbahnhof", "8070004b")
      seed!("Frankfurt am Main Flughafen Fernbahnhof", "8070003b")

      assert {:ok, stations} = StationCatalog.search_stations("Frankfurt(M) Flughafen", [])
      names = Enum.map(stations, & &1.name)

      assert "Frankfurt (Main) Flughafen Regionalbahnhof" in names
      assert "Frankfurt am Main Flughafen Fernbahnhof" in names
    end

    test "matches are case-insensitive" do
      assert {:ok, [_ | _]} = StationCatalog.search_stations("hannover hbf", [])
    end

    test "returns the provider-neutral station shape with a namespaced id" do
      assert {:ok, [station | _rest]} = StationCatalog.search_stations("Hannover Hbf", [])
      assert station.id == %{provider: StationCatalog, value: "8000152"}
      assert station.eva_number == "8000152"
    end

    test "returns no candidates for an unknown place" do
      assert {:ok, []} = StationCatalog.search_stations("Nirgendwo", [])
    end

    test "returns no candidates for a blank query" do
      assert {:ok, []} = StationCatalog.search_stations("  ", [])
    end
  end

  describe "unsupported operations" do
    test "search_connections is unsupported" do
      assert StationCatalog.search_connections(%{}, []) == {:error, :unsupported}
    end

    test "departures and journey report not_found" do
      assert StationCatalog.departures(
               %{},
               ~U[2026-01-01 00:00:00Z],
               ~U[2026-01-01 01:00:00Z],
               []
             ) ==
               {:error, :not_found}

      assert StationCatalog.journey(%{}, []) == {:error, :not_found}
    end
  end

  defp seed!(name, eva_number) do
    %Station{}
    |> Station.changeset(%{name: name, eva_number: eva_number})
    |> Repo.insert!()
  end
end
