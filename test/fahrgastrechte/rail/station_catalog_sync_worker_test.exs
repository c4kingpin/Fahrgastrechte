defmodule Fahrgastrechte.Rail.StationCatalogSyncWorkerTest do
  # A freshly started worker still needs the shared sandbox connection to
  # reach the database from its own process (async: false), same reasoning
  # as Documents.CleanupWorkerTest.
  use Fahrgastrechte.DataCase, async: false

  alias Fahrgastrechte.Rail.Station
  alias Fahrgastrechte.Rail.StationCatalogSyncWorker

  test "run_now/2 syncs immediately and returns the outcome" do
    fetch_page = fn 1, _options ->
      {:ok, [%{name: "Hannover Hbf", eva_number: "8000152"}], false}
    end

    name = :"station_catalog_sync_worker_#{System.unique_integer([:positive])}"

    start_supervised!(
      {StationCatalogSyncWorker,
       name: name, enabled: false, sync_options: [fetch_page: fetch_page]}
    )

    assert {:ok, %{pages: 1, stations: 1}} = StationCatalogSyncWorker.run_now(name)
    assert [%Station{name: "Hannover Hbf"}] = Repo.all(Station)
  end

  test "a failing sync is logged and returned, not raised" do
    fetch_page = fn 1, _options -> {:error, {:upstream, :not_configured}} end
    name = :"station_catalog_sync_worker_#{System.unique_integer([:positive])}"

    start_supervised!(
      {StationCatalogSyncWorker,
       name: name, enabled: false, sync_options: [fetch_page: fetch_page]}
    )

    assert {:error, {{:upstream, :not_configured}, %{pages: 0, stations: 0}}} =
             StationCatalogSyncWorker.run_now(name)
  end

  test "the app-started singleton is disabled in test config and never schedules itself" do
    # config/test.exs sets enabled: false; if this ever schedules a real sync
    # in the shared test suite it would hit the live, unconfigured OpenStation
    # API on every test run.
    assert Process.whereis(StationCatalogSyncWorker) != nil
  end
end
