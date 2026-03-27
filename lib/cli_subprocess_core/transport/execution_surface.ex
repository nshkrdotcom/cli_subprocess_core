defmodule CliSubprocessCore.Transport.ExecutionSurface do
  @moduledoc false

  alias CliSubprocessCore.Transport.LocalSubprocess

  @surface_kinds [:local_subprocess, :static_ssh, :leased_ssh, :guest_bridge]
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

  @type surface_kind :: :local_subprocess | :static_ssh | :leased_ssh | :guest_bridge
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
          dispatch: dispatch(),
          adapter_options: keyword(),
          surface: t()
        }

  @spec default_surface_kind() :: :local_subprocess
  def default_surface_kind, do: @default_surface_kind

  @spec reserved_keys() :: [reserved_key(), ...]
  def reserved_keys, do: @reserved_keys

  @spec supported_surface_kinds() :: [surface_kind(), ...]
  def supported_surface_kinds, do: @surface_kinds

  @spec new(keyword()) :: {:ok, t()} | {:error, validation_error()}
  def new(opts) when is_list(opts) do
    with {:ok, surface_kind} <- normalize_surface_kind(Keyword.get(opts, :surface_kind)),
         {:ok, transport_options} <-
           normalize_transport_options(Keyword.get(opts, :transport_options)),
         :ok <- validate_optional_binary(Keyword.get(opts, :target_id), :target_id),
         :ok <- validate_optional_binary(Keyword.get(opts, :lease_ref), :lease_ref),
         :ok <- validate_optional_binary(Keyword.get(opts, :surface_ref), :surface_ref),
         :ok <- validate_boundary_class(Keyword.get(opts, :boundary_class)),
         :ok <- validate_observability(Keyword.get(opts, :observability, %{})) do
      {:ok,
       %__MODULE__{
         surface_kind: surface_kind,
         transport_options: Keyword.drop(transport_options, @forbidden_transport_option_keys),
         target_id: Keyword.get(opts, :target_id),
         lease_ref: Keyword.get(opts, :lease_ref),
         surface_ref: Keyword.get(opts, :surface_ref),
         boundary_class: Keyword.get(opts, :boundary_class),
         observability: Keyword.get(opts, :observability, %{})
       }}
    end
  end

  @spec resolve(keyword()) ::
          {:ok, resolved()} | {:error, validation_error() | resolution_error()}
  def resolve(opts) when is_list(opts) do
    with {:ok, %__MODULE__{} = surface} <- new(opts),
         {:ok, adapter} <- resolve_adapter(surface.surface_kind),
         :ok <- ensure_adapter_loaded(adapter) do
      {:ok,
       %{
         dispatch: adapter_dispatch(adapter),
         adapter_options:
           opts
           |> Keyword.drop(@reserved_keys)
           |> Keyword.merge(surface.transport_options)
           |> Keyword.merge(surface_metadata(surface)),
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

  def normalize_surface_kind(surface_kind) when surface_kind in @surface_kinds,
    do: {:ok, surface_kind}

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
    if Enum.all?(Map.keys(options), &is_atom/1) do
      {:ok, Enum.into(options, [])}
    else
      {:error, {:invalid_transport_options, options}}
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

  defp resolve_adapter(:local_subprocess), do: {:ok, LocalSubprocess}
  defp resolve_adapter(surface_kind), do: {:error, {:unsupported_surface_kind, surface_kind}}

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
end
