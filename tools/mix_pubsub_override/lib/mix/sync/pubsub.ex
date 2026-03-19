defmodule Mix.Sync.PubSub do
  @moduledoc false

  use GenServer

  @name __MODULE__

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  @spec subscribe(String.t()) :: :ok
  def subscribe(key) when is_binary(key) do
    GenServer.call(@name, {:subscribe, self(), key}, :infinity)
  end

  @spec broadcast(String.t(), term() | (-> term())) :: :ok
  def broadcast(key, message) when is_binary(key) do
    payload =
      case message do
        lazy_message when is_function(lazy_message, 0) -> lazy_message.()
        other -> other
      end

    GenServer.cast(@name, {:broadcast, key, payload})
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:subscribe, pid, key}, _from, state) do
    Process.monitor(pid)

    next_state =
      Map.update(state, key, MapSet.new([pid]), fn subscribers ->
        MapSet.put(subscribers, pid)
      end)

    {:reply, :ok, next_state}
  end

  @impl GenServer
  def handle_cast({:broadcast, key, message}, state) do
    for pid <- Map.get(state, key, MapSet.new()) do
      send(pid, message)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    next_state =
      Enum.reduce(state, %{}, fn {key, subscribers}, acc ->
        case MapSet.delete(subscribers, pid) do
          updated when map_size(updated) == 0 -> acc
          updated -> Map.put(acc, key, updated)
        end
      end)

    {:noreply, next_state}
  end
end
