defmodule Fahrgastrechte.Rail.RateLimiter do
  @moduledoc false

  use GenServer

  @name __MODULE__

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: @name)
  end

  def with_permit(callback) when is_function(callback, 0) do
    case GenServer.call(@name, :checkout) do
      {:ok, token} ->
        try do
          callback.()
        after
          GenServer.cast(@name, {:checkin, token})
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(options) do
    {:ok,
     %{
       rate: Keyword.get(options, :rate, 45),
       window_ms: Keyword.get(options, :window_ms, 60_000),
       max_concurrency: Keyword.get(options, :max_concurrency, 2),
       calls: [],
       active: %{}
     }}
  end

  @impl true
  def handle_call(:checkout, {pid, _tag}, state) do
    now = System.monotonic_time(:millisecond)
    calls = Enum.filter(state.calls, &(now - &1 < state.window_ms))

    if length(calls) < state.rate and map_size(state.active) < state.max_concurrency do
      token = make_ref()
      monitor = Process.monitor(pid)

      {:reply, {:ok, token},
       %{state | calls: [now | calls], active: Map.put(state.active, token, {pid, monitor})}}
    else
      {:reply, {:error, :rate_limited}, %{state | calls: calls}}
    end
  end

  @impl true
  def handle_cast({:checkin, token}, state) do
    {:noreply, release(state, token)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    token =
      Enum.find_value(state.active, fn {token, {_pid, active_monitor}} ->
        if active_monitor == monitor, do: token
      end)

    {:noreply, if(token, do: release(state, token), else: state)}
  end

  defp release(state, token) do
    case Map.pop(state.active, token) do
      {nil, _active} ->
        state

      {{_pid, monitor}, active} ->
        Process.demonitor(monitor, [:flush])
        %{state | active: active}
    end
  end
end
