defmodule Fahrgastrechte.Documents.CleanupWorker do
  @moduledoc """
  Retries physical document deletions that a previous request could not finish.

  A failed file removal leaves the row marked pending, which already hides it
  from lists and downloads. Retrying that removal is maintenance on data the
  system owns, so it runs here on a schedule rather than as a side effect of
  somebody reading their documents.
  """

  use GenServer

  require Logger

  alias Fahrgastrechte.Documents

  @default_interval_ms :timer.minutes(15)
  # Deletions that failed because of a transient storage problem should be
  # retried soon after a restart, but not while the node is still booting.
  @default_initial_delay_ms :timer.seconds(30)

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "Runs one sweep immediately and returns how many rows it processed."
  @spec sweep_now(GenServer.server(), timeout()) :: {:ok, non_neg_integer()}
  def sweep_now(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :sweep, timeout)
  end

  @impl true
  def init(options) do
    state = %{
      interval_ms: Keyword.get(options, :interval_ms, @default_interval_ms),
      initial_delay_ms: Keyword.get(options, :initial_delay_ms, @default_initial_delay_ms)
    }

    if Keyword.get(options, :enabled, true) do
      Process.send_after(self(), :sweep, state.initial_delay_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:reply, sweep(), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, state.interval_ms)
    {:noreply, state}
  end

  defp sweep do
    {:ok, count} = Documents.cleanup_pending_documents()

    if count > 0 do
      Logger.info("retried #{count} pending document deletions")
    end

    {:ok, count}
  rescue
    # A sweep must never take the worker down; the next tick tries again.
    exception ->
      Logger.warning("document cleanup sweep failed: #{Exception.message(exception)}")
      {:ok, 0}
  end
end
