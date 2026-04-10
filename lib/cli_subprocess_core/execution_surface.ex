defmodule CliSubprocessCore.ExecutionSurface do
  @moduledoc """
  Backward-compatible execution-surface facade for downstream CLI packages.

  `cli_subprocess_core` no longer owns the transport substrate. This module
  preserves the historical `CliSubprocessCore.ExecutionSurface` struct while
  delegating validation and capability lookup to
  `ExecutionPlane.Process.Transport.Surface`.
  """

  alias ExecutionPlane.Process.Transport.Surface, as: RuntimeExecutionSurface

  @runtime_surface ExecutionPlane.Process.Transport.Surface
  @contract_version RuntimeExecutionSurface.contract_version()
  @default_surface_kind RuntimeExecutionSurface.default_surface_kind()

  defstruct contract_version: @contract_version,
            surface_kind: @default_surface_kind,
            transport_options: [],
            target_id: nil,
            lease_ref: nil,
            surface_ref: nil,
            boundary_class: nil,
            observability: %{}

  @type contract_version :: String.t()
  @type surface_kind :: atom()
  @type boundary_class :: atom() | String.t() | nil
  @type reserved_key ::
          :contract_version
          | :surface_kind
          | :transport_options
          | :target_id
          | :lease_ref
          | :surface_ref
          | :boundary_class
          | :observability

  @type t :: %__MODULE__{
          contract_version: contract_version(),
          surface_kind: surface_kind(),
          transport_options: keyword(),
          target_id: String.t() | nil,
          lease_ref: String.t() | nil,
          surface_ref: String.t() | nil,
          boundary_class: boundary_class(),
          observability: map()
        }

  @type projected_t :: %{
          required(:contract_version) => contract_version(),
          required(:surface_kind) => surface_kind(),
          required(:transport_options) => map(),
          required(:target_id) => String.t() | nil,
          required(:lease_ref) => String.t() | nil,
          required(:surface_ref) => String.t() | nil,
          required(:boundary_class) => boundary_class(),
          required(:observability) => map()
        }

  @type validation_error :: term()
  @type resolution_error :: term()
  @type resolved :: map()

  @spec default_surface_kind() :: surface_kind()
  def default_surface_kind, do: runtime_surface_apply(:default_surface_kind, [])

  @spec contract_version() :: contract_version()
  def contract_version, do: runtime_surface_apply(:contract_version, [])

  @spec reserved_keys() :: [reserved_key(), ...]
  def reserved_keys, do: runtime_surface_apply(:reserved_keys, [])

  @spec supported_surface_kinds() :: [atom(), ...]
  def supported_surface_kinds, do: runtime_surface_apply(:supported_surface_kinds, [])

  @spec remote_surface_kind?(surface_kind()) :: boolean()
  def remote_surface_kind?(surface_kind),
    do: runtime_surface_apply(:remote_surface_kind?, [surface_kind])

  @spec new(keyword() | map() | t() | struct()) :: {:ok, t()} | {:error, validation_error()}
  def new(%__MODULE__{} = surface), do: {:ok, surface}
  def new(%RuntimeExecutionSurface{} = surface), do: {:ok, from_runtime_surface(surface)}

  def new(attrs) when is_map(attrs) do
    attrs
    |> execution_surface_attrs()
    |> new()
  end

  def new(opts) when is_list(opts) do
    case runtime_surface_apply(:new, [opts]) do
      {:ok, %RuntimeExecutionSurface{} = surface} ->
        {:ok, from_runtime_surface(surface)}

      {:error, _reason} = error ->
        error
    end
  end

  def new(other), do: {:error, {:invalid_execution_surface, other}}

  @spec new!(keyword() | map() | t() | struct()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, %__MODULE__{} = surface} ->
        surface

      {:error, reason} ->
        raise ArgumentError, "invalid execution surface: #{inspect(reason)}"
    end
  end

  @spec capabilities(
          t()
          | struct()
          | atom()
          | keyword()
          | map()
          | nil
        ) ::
          {:ok, term()} | {:error, term()}
  def capabilities(surface), do: runtime_surface_apply(:capabilities, [runtime_input(surface)])

  @spec path_semantics(
          t()
          | struct()
          | atom()
          | keyword()
          | map()
          | nil
        ) ::
          atom() | nil
  def path_semantics(surface),
    do: runtime_surface_apply(:path_semantics, [runtime_input(surface)])

  @spec nonlocal_path_surface?(
          t()
          | struct()
          | atom()
          | keyword()
          | map()
          | nil
        ) ::
          boolean()
  def nonlocal_path_surface?(surface),
    do: runtime_surface_apply(:nonlocal_path_surface?, [runtime_input(surface)])

  @spec remote_surface?(
          t()
          | struct()
          | atom()
          | keyword()
          | map()
          | nil
        ) ::
          boolean()
  def remote_surface?(surface),
    do: runtime_surface_apply(:remote_surface?, [runtime_input(surface)])

  @spec resolve(keyword()) ::
          {:ok, resolved()} | {:error, validation_error() | resolution_error()}
  def resolve(opts) when is_list(opts) do
    case runtime_surface_apply(:resolve, [opts]) do
      {:ok, resolved} ->
        {:ok, %{resolved | surface: from_runtime_surface(resolved.surface)}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec normalize_surface_kind(term()) :: {:ok, surface_kind()} | {:error, term()}
  def normalize_surface_kind(surface_kind),
    do: runtime_surface_apply(:normalize_surface_kind, [surface_kind])

  @spec normalize_transport_options(term()) :: {:ok, keyword()} | {:error, term()}
  def normalize_transport_options(options),
    do: runtime_surface_apply(:normalize_transport_options, [options])

  @spec surface_metadata(t() | struct()) :: keyword()
  def surface_metadata(surface) do
    surface
    |> to_runtime_surface()
    |> then(&runtime_surface_apply(:surface_metadata, [&1]))
  end

  @spec to_map(t() | struct()) :: projected_t()
  def to_map(surface) do
    surface
    |> to_runtime_surface()
    |> then(&runtime_surface_apply(:to_map, [&1]))
  end

  @spec to_runtime_surface(t() | struct()) :: struct()
  def to_runtime_surface(%RuntimeExecutionSurface{} = surface), do: surface

  def to_runtime_surface(%__MODULE__{} = surface) do
    %RuntimeExecutionSurface{
      contract_version: surface.contract_version,
      surface_kind: surface.surface_kind,
      transport_options: surface.transport_options,
      target_id: surface.target_id,
      lease_ref: surface.lease_ref,
      surface_ref: surface.surface_ref,
      boundary_class: surface.boundary_class,
      observability: surface.observability
    }
  end

  @spec from_runtime_surface(struct()) :: t()
  def from_runtime_surface(%RuntimeExecutionSurface{} = surface) do
    %__MODULE__{
      contract_version: surface.contract_version,
      surface_kind: surface.surface_kind,
      transport_options: surface.transport_options,
      target_id: surface.target_id,
      lease_ref: surface.lease_ref,
      surface_ref: surface.surface_ref,
      boundary_class: surface.boundary_class,
      observability: surface.observability
    }
  end

  defp runtime_input(%__MODULE__{} = surface), do: to_runtime_surface(surface)
  defp runtime_input(other), do: other

  defp execution_surface_attrs(attrs) do
    [
      contract_version: Map.get(attrs, :contract_version, Map.get(attrs, "contract_version")),
      surface_kind: Map.get(attrs, :surface_kind, Map.get(attrs, "surface_kind")),
      transport_options: Map.get(attrs, :transport_options, Map.get(attrs, "transport_options")),
      target_id: Map.get(attrs, :target_id, Map.get(attrs, "target_id")),
      lease_ref: Map.get(attrs, :lease_ref, Map.get(attrs, "lease_ref")),
      surface_ref: Map.get(attrs, :surface_ref, Map.get(attrs, "surface_ref")),
      boundary_class: Map.get(attrs, :boundary_class, Map.get(attrs, "boundary_class")),
      observability: Map.get(attrs, :observability, Map.get(attrs, "observability", %{}))
    ]
  end

  defp runtime_surface_apply(function_name, args) do
    apply(@runtime_surface, function_name, args)
  end
end
