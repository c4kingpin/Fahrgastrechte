defmodule Fahrgastrechte.Rail.StationCatalogSyncWorker do
  @moduledoc """
  Periodically refreshes the local station catalog from OpenStation.

  Station master data changes rarely, so a monthly refresh keeps suggestions
  current without hammering the upstream API. See
  `Fahrgastrechte.Rail.StationCatalogSync` for the actual crawl; this worker
  only owns the schedule.
  """

  use GenServer

  require Logger

  alias Fahrgastrechte.Rail.StationCatalogSync

  @default_interval_ms :timer.hours(24 * 30)
  # The catalog crawl takes a minute or two; give the app a moment to finish
  # booting first rather than racing it against startup.
  @default_initial_delay_ms :timer.seconds(60)

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "Runs one sync immediately and returns its outcome."
  @spec run_now(GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  def run_now(server \\ __MODULE__, timeout \\ 120_000) do
    GenServer.call(server, :sync, timeout)
  end

  @impl true
  def init(options) do
    state = %{
      interval_ms: Keyword.get(options, :interval_ms, @default_interval_ms),
      initial_delay_ms: Keyword.get(options, :initial_delay_ms, @default_initial_delay_ms),
      sync_options: Keyword.get(options, :sync_options, [])
    }

    if Keyword.get(options, :enabled, true) do
      Process.send_after(self(), :sync, state.initial_delay_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, sync(state.sync_options), state}
  end

  @impl true
  def handle_info(:sync, state) do
    sync(state.sync_options)
    Process.send_after(self(), :sync, state.interval_ms)
    {:noreply, state}
  end

  defp sync(sync_options) do
    case StationCatalogSync.run(sync_options) do
      {:ok, %{pages: pages, stations: stations}} = result ->
        Logger.info("station catalog sync completed: #{pages} pages, #{stations} stations")
        result

      {:error, {reason, %{pages: pages, stations: stations}}} = result ->
        Logger.warning(
          "station catalog sync stopped early after #{pages} pages " <>
            "(#{stations} stations upserted): #{inspect(reason)}"
        )

        result
    end
  rescue
    # A sync must never take the worker down; the next tick tries again.
    exception ->
      Logger.warning("station catalog sync failed: #{Exception.message(exception)}")
      {:error, {:exception, Exception.message(exception)}}
  end
end
