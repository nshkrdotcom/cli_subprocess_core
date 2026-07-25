defmodule CliSubprocessCore.EphemeralFiles do
  @moduledoc """
  Owner-monitored lifecycle for temporary files a provider invocation needs on
  disk for the lifetime of a run.

  A run may end in six different ways — a normal result, an error, an
  interrupt, an explicit close, the death of the process that owns the run, or
  a forced teardown — and a temporary file must not survive any of them. An
  `after` block covers the first four; it does not run when the owner is killed
  untrappably. This process therefore holds the guarantee instead of the owner:
  it monitors the owner and removes the owner's files when that monitor fires.

  Removal is a single `File.rm/1`, so a forced teardown is bounded by
  construction.
  """

  use GenServer

  @type path :: Path.t()

  @doc """
  Starts the tracker. The application supervisor starts the singleton; tests
  may start isolated instances with `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Tracks `path` on behalf of `owner`. When `owner` exits for any reason the
  file is removed.
  """
  @spec track(path(), pid(), GenServer.server()) :: :ok | {:error, :tracker_unavailable}
  def track(path, owner \\ self(), server \\ __MODULE__)
      when is_binary(path) and is_pid(owner) do
    GenServer.call(server, {:track, path, owner})
  catch
    :exit, _reason -> {:error, :tracker_unavailable}
  end

  @doc """
  Removes `path` now and stops tracking it. Safe to call more than once.
  """
  @spec release(path(), GenServer.server()) :: :ok
  def release(path, server \\ __MODULE__) when is_binary(path) do
    GenServer.call(server, {:release, path})
  catch
    :exit, _reason ->
      _ = File.rm(path)
      :ok
  end

  @doc """
  Whether `path` is currently tracked. Intended for tests and diagnostics.
  """
  @spec tracked?(path(), GenServer.server()) :: boolean()
  def tracked?(path, server \\ __MODULE__) when is_binary(path) do
    GenServer.call(server, {:tracked?, path})
  catch
    :exit, _reason -> false
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{owner_of: %{}, owners: %{}}}

  @impl GenServer
  def handle_call({:track, path, owner}, _from, state) do
    {:reply, :ok, put_path(state, path, owner)}
  end

  def handle_call({:release, path}, _from, state) do
    _ = File.rm(path)
    {:reply, :ok, drop_path(state, path)}
  end

  def handle_call({:tracked?, path}, _from, state) do
    {:reply, Map.has_key?(state.owner_of, path), state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, owner, _reason}, state) do
    case Map.pop(state.owners, owner) do
      {nil, _owners} ->
        {:noreply, state}

      {{_ref, paths}, owners} ->
        Enum.each(paths, &File.rm/1)
        {:noreply, %{state | owners: owners, owner_of: Map.drop(state.owner_of, paths)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp put_path(state, path, owner) do
    if Map.has_key?(state.owner_of, path) do
      state
    else
      {ref, paths} = Map.get_lazy(state.owners, owner, fn -> {Process.monitor(owner), []} end)

      %{
        state
        | owner_of: Map.put(state.owner_of, path, owner),
          owners: Map.put(state.owners, owner, {ref, [path | paths]})
      }
    end
  end

  defp drop_path(state, path) do
    case Map.pop(state.owner_of, path) do
      {nil, owner_of} ->
        %{state | owner_of: owner_of}

      {owner, owner_of} ->
        %{state | owner_of: owner_of, owners: drop_owner_path(state.owners, owner, path)}
    end
  end

  defp drop_owner_path(owners, owner, path) do
    case Map.fetch(owners, owner) do
      :error ->
        owners

      {:ok, {ref, paths}} ->
        case List.delete(paths, path) do
          [] ->
            Process.demonitor(ref, [:flush])
            Map.delete(owners, owner)

          remaining ->
            Map.put(owners, owner, {ref, remaining})
        end
    end
  end
end
