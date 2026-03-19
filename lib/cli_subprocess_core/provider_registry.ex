defmodule CliSubprocessCore.ProviderRegistry do
  @moduledoc """
  Registry of provider profile modules available to the core runtime.
  """

  use GenServer

  alias CliSubprocessCore.ProviderProfile

  defstruct profiles: %{}, built_in_modules: []

  @type t :: %__MODULE__{
          profiles: %{optional(atom()) => module()},
          built_in_modules: [module()]
        }

  @doc """
  Starts a provider registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {genserver_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, genserver_opts)
  end

  @doc """
  Registers a provider profile module in the registry.
  """
  @spec register(module(), GenServer.server()) ::
          :ok
          | {:error, {:module_not_loaded, module()}}
          | {:error, {:missing_callbacks, module(), [{atom(), non_neg_integer()}]}}
          | {:error, {:behaviour_not_declared, module()}}
          | {:error, {:duplicate_profile_id, atom(), module(), module()}}
  def register(profile_module, registry \\ __MODULE__) when is_atom(profile_module) do
    GenServer.call(registry, {:register, profile_module, false})
  end

  @doc """
  Registers multiple provider profile modules in order.
  """
  @spec register_many([module()], GenServer.server()) ::
          :ok
          | {:error, {:module_not_loaded, module()}}
          | {:error, {:missing_callbacks, module(), [{atom(), non_neg_integer()}]}}
          | {:error, {:behaviour_not_declared, module()}}
          | {:error, {:duplicate_profile_id, atom(), module(), module()}}
  def register_many(profile_modules, registry \\ __MODULE__) when is_list(profile_modules) do
    Enum.reduce_while(profile_modules, :ok, fn profile_module, :ok ->
      case register(profile_module, registry) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Fetches a provider profile module by id.
  """
  @spec fetch(atom(), GenServer.server()) :: {:ok, module()} | :error
  def fetch(id, registry \\ __MODULE__) when is_atom(id) do
    GenServer.call(registry, {:fetch, id})
  end

  @doc """
  Returns `true` when a provider id is registered.
  """
  @spec registered?(atom(), GenServer.server()) :: boolean()
  def registered?(id, registry \\ __MODULE__) when is_atom(id) do
    match?({:ok, _module}, fetch(id, registry))
  end

  @doc """
  Lists the registered provider ids.
  """
  @spec ids(GenServer.server()) :: [atom()]
  def ids(registry \\ __MODULE__) do
    registry
    |> list()
    |> Map.keys()
  end

  @doc """
  Returns the registered provider profile mapping.
  """
  @spec list(GenServer.server()) :: %{optional(atom()) => module()}
  def list(registry \\ __MODULE__) do
    GenServer.call(registry, :list)
  end

  @doc """
  Returns the built-in provider profile modules loaded at registry boot.
  """
  @spec built_in_modules(GenServer.server()) :: [module()]
  def built_in_modules(registry \\ __MODULE__) do
    GenServer.call(registry, :built_in_modules)
  end

  @impl GenServer
  def init(opts) do
    profile_modules = Keyword.get(opts, :profile_modules, [])

    case register_initial_modules(profile_modules) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:register, profile_module, built_in?}, _from, state) do
    case put_profile_module(state, profile_module, built_in?) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:fetch, id}, _from, state) do
    reply =
      case Map.fetch(state.profiles, id) do
        {:ok, profile_module} -> {:ok, profile_module}
        :error -> :error
      end

    {:reply, reply, state}
  end

  def handle_call(:list, _from, state), do: {:reply, state.profiles, state}
  def handle_call(:built_in_modules, _from, state), do: {:reply, state.built_in_modules, state}

  defp register_initial_modules(profile_modules) do
    Enum.reduce_while(profile_modules, {:ok, %__MODULE__{}}, fn profile_module, {:ok, state} ->
      case put_profile_module(state, profile_module, true) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp put_profile_module(state, profile_module, built_in?) do
    with :ok <- ProviderProfile.ensure_module(profile_module) do
      id = profile_module.id()

      case Map.fetch(state.profiles, id) do
        {:ok, ^profile_module} ->
          {:ok, maybe_mark_built_in(state, profile_module, built_in?)}

        {:ok, existing_module} ->
          {:error, {:duplicate_profile_id, id, existing_module, profile_module}}

        :error ->
          next_state =
            state
            |> put_in([Access.key(:profiles), id], profile_module)
            |> maybe_mark_built_in(profile_module, built_in?)

          {:ok, next_state}
      end
    end
  end

  defp maybe_mark_built_in(state, _profile_module, false), do: state

  defp maybe_mark_built_in(state, profile_module, true) do
    if profile_module in state.built_in_modules do
      state
    else
      %{state | built_in_modules: state.built_in_modules ++ [profile_module]}
    end
  end
end
