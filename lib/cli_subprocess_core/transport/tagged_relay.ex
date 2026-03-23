defmodule CliSubprocessCore.Transport.TaggedRelay do
  @moduledoc false

  use GenServer

  @type event_mapper :: (term() -> [term()])

  @spec start(pid(), reference(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(target_pid, target_tag, opts)
      when is_pid(target_pid) and is_reference(target_tag) and is_list(opts) do
    GenServer.start(__MODULE__, {target_pid, target_tag, opts})
  end

  @spec attach_transport(pid(), pid()) :: :ok
  def attach_transport(relay, transport) when is_pid(relay) and is_pid(transport) do
    GenServer.cast(relay, {:attach_transport, transport})
  catch
    :exit, _reason ->
      :ok
  end

  @spec stop(pid()) :: :ok
  def stop(relay) when is_pid(relay) do
    GenServer.stop(relay, :normal)
  catch
    :exit, _reason ->
      :ok
  end

  @impl GenServer
  def init({target_pid, target_tag, opts}) do
    state = %{
      target_pid: target_pid,
      target_tag: target_tag,
      target_monitor_ref: Process.monitor(target_pid),
      transport_monitor_ref: nil,
      core_event_tag: Keyword.fetch!(opts, :core_event_tag),
      core_ref: Keyword.fetch!(opts, :core_ref),
      public_event_tag: Keyword.fetch!(opts, :public_event_tag),
      event_mapper: Keyword.fetch!(opts, :event_mapper)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:attach_transport, transport}, state) when is_pid(transport) do
    state = maybe_replace_transport_monitor(state, transport)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({tag, ref, event}, %{core_event_tag: tag, core_ref: ref} = state) do
    state
    |> mapped_events(event)
    |> Enum.each(&forward_event(state, &1))

    case event do
      {:exit, _reason} ->
        cleanup_monitors(state)
        {:stop, :normal, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    cond do
      monitor_ref == state.target_monitor_ref ->
        cleanup_monitors(state)
        {:stop, :normal, state}

      monitor_ref == state.transport_monitor_ref ->
        cleanup_monitors(state)
        {:stop, :normal, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp maybe_replace_transport_monitor(%{transport_monitor_ref: monitor_ref} = state, transport) do
    if is_reference(monitor_ref), do: Process.demonitor(monitor_ref, [:flush])
    %{state | transport_monitor_ref: Process.monitor(transport)}
  end

  defp mapped_events(%{event_mapper: mapper}, event) when is_function(mapper, 1) do
    case mapper.(event) do
      events when is_list(events) -> events
      _other -> []
    end
  end

  defp forward_event(%{target_pid: pid, target_tag: tag, public_event_tag: event_tag}, event) do
    Kernel.send(pid, {event_tag, tag, event})
  end

  defp cleanup_monitors(%{target_monitor_ref: target_ref, transport_monitor_ref: transport_ref}) do
    if is_reference(target_ref), do: Process.demonitor(target_ref, [:flush])
    if is_reference(transport_ref), do: Process.demonitor(transport_ref, [:flush])
  end
end
