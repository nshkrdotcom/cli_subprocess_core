defmodule CliSubprocessCore.ExecutionSurface do
  @moduledoc """
  Public execution-surface contract for process placement and transport routing.

  This contract is intentionally narrow:

  - `surface_kind` selects the runtime surface
  - `transport_options` carries transport-only data
  - `target_id`, `lease_ref`, `surface_ref`, and `boundary_class` stay typed
  - `observability` remains an opaque metadata bag

  Provider family, command selection, and process launch arguments do not
  belong in `ExecutionSurface`.
  """

  alias CliSubprocessCore.ExecutionSurface.{Capabilities, Registry}

  @default_surface_kind :local_subprocess
  @reserved_keys [
    :surface_kind,
    :transport_options,
    :target_id,
    :lease_ref,
    :surface_ref,
    :boundary_class,
    :observability
  ]
  @forbidden_transport_option_keys [:command, :args, :cwd, :env, :clear_env?, :user]

  defstruct surface_kind: @default_surface_kind,
            transport_options: [],
            target_id: nil,
            lease_ref: nil,
            surface_ref: nil,
            boundary_class: nil,
            observability: %{}

  @type surface_kind :: :local_subprocess | :ssh_exec | :guest_bridge
  @type reserved_key ::
          :surface_kind
          | :transport_options
          | :target_id
          | :lease_ref
          | :surface_ref
          | :boundary_class
          | :observability

  @type t :: %__MODULE__{
          surface_kind: surface_kind(),
          transport_options: keyword(),
          target_id: String.t() | nil,
          lease_ref: String.t() | nil,
          surface_ref: String.t() | nil,
          boundary_class: atom() | nil,
          observability: map()
        }

  @type validation_error ::
          {:invalid_surface_kind, term()}
          | {:invalid_transport_options, term()}
          | {:invalid_execution_surface, term()}
          | {:invalid_target_id, term()}
          | {:invalid_lease_ref, term()}
          | {:invalid_surface_ref, term()}
          | {:invalid_boundary_class, term()}
          | {:invalid_observability, term()}
          | {:adapter_not_loaded, module()}

  @type resolution_error :: {:unsupported_surface_kind, surface_kind()}

  @type dispatch :: %{
          start: function(),
          start_link: function(),
          run: function()
        }

  @type resolved :: %{
          adapter_capabilities: Capabilities.t(),
          dispatch: dispatch(),
          adapter_options: keyword(),
          surface: t()
        }

  @spec default_surface_kind() :: :local_subprocess
  def default_surface_kind, do: @default_surface_kind

  @spec reserved_keys() :: [reserved_key(), ...]
  def reserved_keys, do: @reserved_keys

  @spec supported_surface_kinds() :: [surface_kind(), ...]
  def supported_surface_kinds, do: Registry.supported_surface_kinds()

  @spec remote_surface_kind?(surface_kind()) :: boolean()
  def remote_surface_kind?(surface_kind) when is_atom(surface_kind) do
    case adapter_capabilities(surface_kind) do
      {:ok, %Capabilities{remote?: remote?}} -> remote?
      {:error, _reason} -> false
    end
  end

  @spec remote_surface?(t() | surface_kind() | keyword() | map() | nil) :: boolean()
  def remote_surface?(%__MODULE__{surface_kind: surface_kind}),
    do: remote_surface_kind?(surface_kind)

  def remote_surface?(surface_kind) when is_atom(surface_kind),
    do: remote_surface_kind?(surface_kind)

  def remote_surface?(opts) when is_list(opts) do
    case execution_surface_attrs(opts) do
      {:ok, attrs} ->
        case Keyword.get(attrs, :surface_kind) do
          surface_kind when is_atom(surface_kind) -> remote_surface_kind?(surface_kind)
          _other -> false
        end

      {:error, _reason} ->
        false
    end
  end

  def remote_surface?(%{} = surface) do
    case Map.get(surface, :__struct__) do
      __MODULE__ ->
        remote_surface?(Map.get(surface, :surface_kind))

      _other ->
        remote_surface?(Map.get(surface, :surface_kind, Map.get(surface, "surface_kind")))
    end
  end

  def remote_surface?(_other), do: false

  @spec new(keyword()) :: {:ok, t()} | {:error, validation_error()}
  def new(opts) when is_list(opts) do
    with {:ok, attrs} <- execution_surface_attrs(opts),
         {:ok, surface_kind} <- normalize_surface_kind(Keyword.get(attrs, :surface_kind)),
         {:ok, transport_options} <-
           normalize_transport_options(Keyword.get(attrs, :transport_options)),
         :ok <- validate_optional_binary(Keyword.get(attrs, :target_id), :target_id),
         :ok <- validate_optional_binary(Keyword.get(attrs, :lease_ref), :lease_ref),
         :ok <- validate_optional_binary(Keyword.get(attrs, :surface_ref), :surface_ref),
         :ok <- validate_boundary_class(Keyword.get(attrs, :boundary_class)),
         :ok <- validate_observability(Keyword.get(attrs, :observability, %{})) do
      {:ok,
       %__MODULE__{
         surface_kind: surface_kind,
         transport_options: Keyword.drop(transport_options, @forbidden_transport_option_keys),
         target_id: Keyword.get(attrs, :target_id),
         lease_ref: Keyword.get(attrs, :lease_ref),
         surface_ref: Keyword.get(attrs, :surface_ref),
         boundary_class: Keyword.get(attrs, :boundary_class),
         observability: Keyword.get(attrs, :observability, %{})
       }}
    end
  end

  @spec resolve(keyword()) ::
          {:ok, resolved()} | {:error, validation_error() | resolution_error()}
  def resolve(opts) when is_list(opts) do
    with {:ok, %__MODULE__{} = surface} <- new(opts),
         {:ok, adapter} <- Registry.fetch(surface.surface_kind),
         :ok <- ensure_adapter_loaded(adapter),
         {:ok, %Capabilities{} = adapter_capabilities} <- normalize_adapter_capabilities(adapter),
         {:ok, transport_options} <-
           adapter.normalize_transport_options(surface.transport_options) do
      {:ok,
       %{
         adapter_capabilities: adapter_capabilities,
         dispatch: adapter_dispatch(adapter),
         adapter_options:
           build_adapter_options(opts, surface, transport_options, adapter_capabilities),
         surface: surface
       }}
    else
      {:error, _reason} = error ->
        error
    end
  end

  @spec normalize_surface_kind(term()) ::
          {:ok, surface_kind()} | {:error, {:invalid_surface_kind, term()}}
  def normalize_surface_kind(nil), do: {:ok, @default_surface_kind}

  def normalize_surface_kind(surface_kind) when is_atom(surface_kind) do
    if Registry.registered?(surface_kind) do
      {:ok, surface_kind}
    else
      {:error, {:invalid_surface_kind, surface_kind}}
    end
  end

  def normalize_surface_kind(surface_kind), do: {:error, {:invalid_surface_kind, surface_kind}}

  @spec normalize_transport_options(term()) ::
          {:ok, keyword()} | {:error, {:invalid_transport_options, term()}}
  def normalize_transport_options(nil), do: {:ok, []}

  def normalize_transport_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      {:ok, options}
    else
      {:error, {:invalid_transport_options, options}}
    end
  end

  def normalize_transport_options(options) when is_map(options) do
    case Enum.reduce_while(options, [], &normalize_transport_option_pair/2) do
      :error ->
        {:error, {:invalid_transport_options, options}}

      normalized ->
        {:ok, Enum.reverse(normalized)}
    end
  end

  def normalize_transport_options(options), do: {:error, {:invalid_transport_options, options}}

  @spec surface_metadata(t()) :: keyword()
  def surface_metadata(%__MODULE__{} = surface) do
    [
      surface_kind: surface.surface_kind,
      target_id: surface.target_id,
      lease_ref: surface.lease_ref,
      surface_ref: surface.surface_ref,
      boundary_class: surface.boundary_class,
      observability: surface.observability
    ]
  end

  defp adapter_dispatch(adapter) when is_atom(adapter) do
    %{
      start: &adapter.start/1,
      start_link: &adapter.start_link/1,
      run: &adapter.run/2
    }
  end

  defp ensure_adapter_loaded(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) do
      :ok
    else
      {:error, {:adapter_not_loaded, adapter}}
    end
  end

  defp normalize_adapter_capabilities(adapter) when is_atom(adapter) do
    capabilities = adapter.capabilities()

    case Capabilities.new(capabilities) do
      {:ok, %Capabilities{} = normalized} ->
        {:ok, normalized}

      {:error, reason} ->
        {:error, {:invalid_transport_options, {:invalid_adapter_capabilities, reason}}}
    end
  end

  defp build_adapter_options(
         opts,
         %__MODULE__{} = surface,
         transport_options,
         adapter_capabilities
       )
       when is_list(opts) and is_list(transport_options) and
              is_struct(adapter_capabilities, Capabilities) do
    opts
    |> Keyword.drop(@reserved_keys)
    |> Keyword.put(:transport_options, transport_options)
    |> Keyword.merge(surface_metadata(surface))
    |> Keyword.put(:adapter_capabilities, adapter_capabilities)
    |> maybe_put_effective_capabilities(surface.surface_kind, adapter_capabilities)
  end

  defp maybe_put_effective_capabilities(opts, :guest_bridge, _adapter_capabilities), do: opts

  defp maybe_put_effective_capabilities(
         opts,
         _surface_kind,
         %Capabilities{} = adapter_capabilities
       ) do
    Keyword.put(opts, :effective_capabilities, adapter_capabilities)
  end

  defp validate_optional_binary(nil, _field), do: :ok
  defp validate_optional_binary(value, _field) when is_binary(value) and value != "", do: :ok
  defp validate_optional_binary(value, field), do: {:error, {:"invalid_#{field}", value}}

  defp validate_boundary_class(nil), do: :ok
  defp validate_boundary_class(boundary_class) when is_atom(boundary_class), do: :ok

  defp validate_boundary_class(boundary_class),
    do: {:error, {:invalid_boundary_class, boundary_class}}

  defp validate_observability(observability) when is_map(observability), do: :ok

  defp validate_observability(observability),
    do: {:error, {:invalid_observability, observability}}

  defp normalize_transport_option_key(key) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end

  defp normalize_transport_option_pair({key, value}, acc) when is_atom(key) do
    {:cont, [{key, value} | acc]}
  end

  defp normalize_transport_option_pair({key, value}, acc) when is_binary(key) do
    case normalize_transport_option_key(key) do
      {:ok, normalized_key} -> {:cont, [{normalized_key, value} | acc]}
      :error -> {:halt, :error}
    end
  end

  defp normalize_transport_option_pair(_other, _acc), do: {:halt, :error}

  defp execution_surface_attrs(opts) when is_list(opts) do
    case Keyword.get(opts, :execution_surface) do
      nil ->
        {:ok, Keyword.take(opts, @reserved_keys)}

      execution_surface ->
        normalize_execution_surface(execution_surface)
    end
  end

  defp normalize_execution_surface(%__MODULE__{} = surface) do
    {:ok,
     [
       transport_options: surface.transport_options
     ] ++ surface_metadata(surface)}
  end

  defp normalize_execution_surface(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      {:ok, Keyword.take(attrs, @reserved_keys)}
    else
      {:error, {:invalid_execution_surface, attrs}}
    end
  end

  defp normalize_execution_surface(attrs) when is_map(attrs) do
    {:ok,
     [
       surface_kind: Map.get(attrs, :surface_kind, Map.get(attrs, "surface_kind")),
       transport_options: Map.get(attrs, :transport_options, Map.get(attrs, "transport_options")),
       target_id: Map.get(attrs, :target_id, Map.get(attrs, "target_id")),
       lease_ref: Map.get(attrs, :lease_ref, Map.get(attrs, "lease_ref")),
       surface_ref: Map.get(attrs, :surface_ref, Map.get(attrs, "surface_ref")),
       boundary_class: Map.get(attrs, :boundary_class, Map.get(attrs, "boundary_class")),
       observability: Map.get(attrs, :observability, Map.get(attrs, "observability", %{}))
     ]}
  end

  defp normalize_execution_surface(attrs), do: {:error, {:invalid_execution_surface, attrs}}

  defp adapter_capabilities(surface_kind) when is_atom(surface_kind) do
    with {:ok, adapter} <- Registry.fetch(surface_kind),
         :ok <- ensure_adapter_loaded(adapter),
         {:ok, %Capabilities{} = capabilities} <- normalize_adapter_capabilities(adapter) do
      {:ok, capabilities}
    end
  end
end
