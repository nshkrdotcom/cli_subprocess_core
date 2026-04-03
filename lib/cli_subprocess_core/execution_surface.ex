defmodule CliSubprocessCore.ExecutionSurface do
  @moduledoc """
  Backward-compatible execution-surface facade for downstream CLI packages.

  `cli_subprocess_core` no longer owns the transport substrate. This module
  preserves the historical `CliSubprocessCore.ExecutionSurface` struct and
  delegates validation and transport capability lookup to
  `ExternalRuntimeTransport.ExecutionSurface`.
  """

  alias ExternalRuntimeTransport.ExecutionSurface, as: TransportExecutionSurface
  alias ExternalRuntimeTransport.ExecutionSurface.Capabilities

  defstruct contract_version: TransportExecutionSurface.contract_version(),
            surface_kind: TransportExecutionSurface.default_surface_kind(),
            transport_options: [],
            target_id: nil,
            lease_ref: nil,
            surface_ref: nil,
            boundary_class: nil,
            observability: %{}

  @type t :: %__MODULE__{
          contract_version: TransportExecutionSurface.contract_version(),
          surface_kind: TransportExecutionSurface.surface_kind(),
          transport_options: keyword(),
          target_id: String.t() | nil,
          lease_ref: String.t() | nil,
          surface_ref: String.t() | nil,
          boundary_class: TransportExecutionSurface.boundary_class(),
          observability: map()
        }

  @type projected_t :: %{
          required(:contract_version) => String.t(),
          required(:surface_kind) => TransportExecutionSurface.surface_kind(),
          required(:transport_options) => map(),
          required(:target_id) => String.t() | nil,
          required(:lease_ref) => String.t() | nil,
          required(:surface_ref) => String.t() | nil,
          required(:boundary_class) => TransportExecutionSurface.boundary_class(),
          required(:observability) => map()
        }

  @type validation_error :: TransportExecutionSurface.validation_error()
  @type resolution_error :: TransportExecutionSurface.resolution_error()
  @type resolved :: TransportExecutionSurface.resolved()

  @spec default_surface_kind() :: TransportExecutionSurface.surface_kind()
  defdelegate default_surface_kind(), to: TransportExecutionSurface

  @spec contract_version() :: String.t()
  defdelegate contract_version(), to: TransportExecutionSurface

  @spec reserved_keys() :: [TransportExecutionSurface.reserved_key(), ...]
  defdelegate reserved_keys(), to: TransportExecutionSurface

  @spec supported_surface_kinds() :: [TransportExecutionSurface.adapter_surface_kind(), ...]
  defdelegate supported_surface_kinds(), to: TransportExecutionSurface

  @spec remote_surface_kind?(TransportExecutionSurface.surface_kind()) :: boolean()
  defdelegate remote_surface_kind?(surface_kind), to: TransportExecutionSurface

  @spec new(keyword() | map() | t() | TransportExecutionSurface.t()) ::
          {:ok, t()} | {:error, validation_error()}
  def new(%__MODULE__{} = surface), do: {:ok, surface}
  def new(%TransportExecutionSurface{} = surface), do: {:ok, from_external(surface)}

  def new(attrs) when is_map(attrs) do
    attrs
    |> execution_surface_attrs()
    |> new()
  end

  def new(opts) when is_list(opts) do
    case TransportExecutionSurface.new(opts) do
      {:ok, %TransportExecutionSurface{} = surface} ->
        {:ok, from_external(surface)}

      {:error, _reason} = error ->
        error
    end
  end

  def new(other), do: {:error, {:invalid_execution_surface, other}}

  @spec new!(keyword() | map() | t() | TransportExecutionSurface.t()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, %__MODULE__{} = surface} ->
        surface

      {:error, reason} ->
        raise ArgumentError, "invalid execution surface: #{inspect(reason)}"
    end
  end

  @spec capabilities(t() | TransportExecutionSurface.t() | atom() | keyword() | map() | nil) ::
          {:ok, Capabilities.t()} | {:error, term()}
  def capabilities(surface), do: TransportExecutionSurface.capabilities(external_input(surface))

  @spec path_semantics(t() | TransportExecutionSurface.t() | atom() | keyword() | map() | nil) ::
          Capabilities.path_semantics() | nil
  def path_semantics(surface),
    do: TransportExecutionSurface.path_semantics(external_input(surface))

  @spec nonlocal_path_surface?(
          t()
          | TransportExecutionSurface.t()
          | atom()
          | keyword()
          | map()
          | nil
        ) :: boolean()
  def nonlocal_path_surface?(surface),
    do: TransportExecutionSurface.nonlocal_path_surface?(external_input(surface))

  @spec remote_surface?(t() | TransportExecutionSurface.t() | atom() | keyword() | map() | nil) ::
          boolean()
  def remote_surface?(surface),
    do: TransportExecutionSurface.remote_surface?(external_input(surface))

  @spec resolve(keyword()) ::
          {:ok, resolved()} | {:error, validation_error() | resolution_error()}
  def resolve(opts) when is_list(opts) do
    case TransportExecutionSurface.resolve(opts) do
      {:ok, resolved} ->
        {:ok, %{resolved | surface: from_external(resolved.surface)}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec normalize_surface_kind(term()) ::
          {:ok, TransportExecutionSurface.surface_kind()}
          | {:error, {:invalid_surface_kind, term()}}
  defdelegate normalize_surface_kind(surface_kind), to: TransportExecutionSurface

  @spec normalize_transport_options(term()) ::
          {:ok, keyword()} | {:error, {:invalid_transport_options, term()}}
  defdelegate normalize_transport_options(options), to: TransportExecutionSurface

  @spec surface_metadata(t() | TransportExecutionSurface.t()) :: keyword()
  def surface_metadata(%__MODULE__{} = surface) do
    surface
    |> to_external()
    |> TransportExecutionSurface.surface_metadata()
  end

  def surface_metadata(%TransportExecutionSurface{} = surface),
    do: TransportExecutionSurface.surface_metadata(surface)

  @spec to_map(t() | TransportExecutionSurface.t()) :: projected_t()
  def to_map(surface), do: surface |> to_external() |> TransportExecutionSurface.to_map()

  @spec to_external(t() | TransportExecutionSurface.t()) :: TransportExecutionSurface.t()
  def to_external(%TransportExecutionSurface{} = surface), do: surface

  def to_external(%__MODULE__{} = surface) do
    %TransportExecutionSurface{
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

  @spec from_external(TransportExecutionSurface.t()) :: t()
  def from_external(%TransportExecutionSurface{} = surface) do
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

  defp external_input(%__MODULE__{} = surface), do: to_external(surface)
  defp external_input(other), do: other

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
end
