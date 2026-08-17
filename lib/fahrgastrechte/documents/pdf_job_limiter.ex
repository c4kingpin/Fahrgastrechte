defmodule Fahrgastrechte.Documents.PDFJobLimiter do
  @moduledoc """
  Bounds how many external PDF-processing jobs (export generation, ticket
  analysis, document classification) run at once across this app instance,
  per docs/decisions/0003-pdf-pipeline.md.
  """

  use GenServer

  @name __MODULE__
  @checkout_retries 8
  @checkout_retry_delay_ms 200

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, @name))
  end

  @doc "Runs `callback` while holding a permit; `{:error, :busy}` if none frees up in time."
  @spec with_permit((-> result), GenServer.server()) :: result | {:error, :busy}
        when result: term()
  def with_permit(callback, server \\ @name) when is_function(callback, 0) do
    case checkout_with_retry(server, @checkout_retries) do
      {:ok, token} ->
        try do
          callback.()
        after
          GenServer.cast(server, {:checkin, token})
        end

      :error ->
        {:error, :busy}
    end
  end

  defp checkout_with_retry(_server, 0), do: :error

  defp checkout_with_retry(server, attempts_left) do
    case GenServer.call(server, :checkout) do
      {:ok, token} ->
        {:ok, token}

      :error ->
        Process.sleep(@checkout_retry_delay_ms)
        checkout_with_retry(server, attempts_left - 1)
    end
  end

  @impl true
  def init(options) do
    {:ok, %{max_concurrency: Keyword.get(options, :max_concurrency, 2), active: %{}}}
  end

  @impl true
  def handle_call(:checkout, {pid, _tag}, state) do
    if map_size(state.active) < state.max_concurrency do
      token = make_ref()
      monitor = Process.monitor(pid)
      {:reply, {:ok, token}, %{state | active: Map.put(state.active, token, monitor)}}
    else
      {:reply, :error, state}
    end
  end

  @impl true
  def handle_cast({:checkin, token}, state) do
    {:noreply, release(state, token)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    token =
      Enum.find_value(state.active, fn {token, active_monitor} ->
        if active_monitor == monitor, do: token
      end)

    {:noreply, if(token, do: release(state, token), else: state)}
  end

  defp release(state, token) do
    case Map.pop(state.active, token) do
      {nil, _active} ->
        state

      {monitor, active} ->
        Process.demonitor(monitor, [:flush])
        %{state | active: active}
    end
  end
end
