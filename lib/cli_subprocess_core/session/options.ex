defmodule CliSubprocessCore.Session.Options do
  @moduledoc """
  Validated startup options for the common session engine.
  """

  alias CliSubprocessCore.{
    ExecutionSurface,
    ProviderProfile,
    ProviderRegistry,
    ProviderRuntimeProfile
  }

  @default_registry ProviderRegistry
  @default_session_event_tag :cli_subprocess_core_session
  @reserved_keys [
    :provider,
    :profile,
    :registry,
    :subscriber,
    :stdin,
    :metadata,
    :session_event_tag,
    :starter,
    :execution_surface,
    :surface_kind,
    :transport_options,
    :target_id,
    :lease_ref,
    :surface_ref,
    :boundary_class,
    :observability
  ]

  defstruct provider: nil,
            profile: nil,
            registry: @default_registry,
            subscriber: nil,
            stdin: nil,
            metadata: %{},
            session_event_tag: @default_session_event_tag,
            surface_kind: ExecutionSurface.default_surface_kind(),
            transport_options: [],
            target_id: nil,
            lease_ref: nil,
            surface_ref: nil,
            boundary_class: nil,
            observability: %{},
            provider_options: [],
            starter: nil

  @type subscriber :: pid() | {pid(), :legacy | reference()} | nil

  @type t :: %__MODULE__{
          provider: atom(),
          profile: module() | nil,
          registry: pid() | atom(),
          subscriber: subscriber(),
          stdin: term(),
          metadata: map(),
          session_event_tag: atom(),
          surface_kind: atom(),
          transport_options: keyword(),
          target_id: String.t() | nil,
          lease_ref: String.t() | nil,
          surface_ref: String.t() | nil,
          boundary_class: atom() | String.t() | nil,
          observability: map(),
          provider_options: keyword(),
          starter: {pid(), reference()} | nil
        }

  @type validation_error ::
          :missing_provider
          | {:invalid_provider, term()}
          | {:invalid_profile, term()}
          | {:provider_profile_mismatch, atom(), atom()}
          | {:invalid_registry, term()}
          | {:unsupported_option, :transport_selector}
          | {:unsupported_option, :simulation_selector}
          | {:invalid_subscriber, term()}
          | {:invalid_metadata, term()}
          | {:invalid_session_event_tag, term()}
          | {:invalid_surface_kind, term()}
          | {:invalid_transport_options, term()}
          | {:invalid_target_id, term()}
          | {:invalid_lease_ref, term()}
          | {:invalid_surface_ref, term()}
          | {:invalid_boundary_class, term()}
          | {:invalid_observability, term()}
          | {:invalid_starter, term()}
          | ProviderRuntimeProfile.resolve_error()

  @doc """
  Builds a validated session options struct.

  Reserved session keys stay on the struct while all remaining keys are passed
  through to the selected provider profile as `provider_options`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, validation_error()}
  def new(opts) when is_list(opts) do
    provider_options = Keyword.drop(opts, @reserved_keys)
    profile = Keyword.get(opts, :profile)

    with {:ok, profile} <- validate_profile(profile),
         {:ok, provider} <- validate_provider(Keyword.get(opts, :provider), profile),
         :ok <- validate_registry(Keyword.get(opts, :registry, @default_registry)),
         :ok <- reject_transport_selector(opts),
         :ok <- reject_public_simulation_selector(opts),
         {:ok, execution_surface} <- ExecutionSurface.new(opts),
         {:ok, {provider_options, execution_surface}} <-
           ProviderRuntimeProfile.resolve(provider, provider_options, execution_surface),
         :ok <- validate_subscriber(Keyword.get(opts, :subscriber)),
         :ok <- validate_metadata(Keyword.get(opts, :metadata, %{})),
         :ok <-
           validate_session_event_tag(
             Keyword.get(opts, :session_event_tag, @default_session_event_tag)
           ),
         :ok <- validate_starter(Keyword.get(opts, :starter)) do
      {:ok,
       %__MODULE__{
         provider: provider,
         profile: profile,
         registry: Keyword.get(opts, :registry, @default_registry),
         subscriber: Keyword.get(opts, :subscriber),
         stdin: Keyword.get(opts, :stdin),
         metadata: Keyword.get(opts, :metadata, %{}),
         session_event_tag: Keyword.get(opts, :session_event_tag, @default_session_event_tag),
         surface_kind: execution_surface.surface_kind,
         transport_options: execution_surface.transport_options,
         target_id: execution_surface.target_id,
         lease_ref: execution_surface.lease_ref,
         surface_ref: execution_surface.surface_ref,
         boundary_class: execution_surface.boundary_class,
         observability: execution_surface.observability,
         provider_options: provider_options,
         starter: Keyword.get(opts, :starter)
       }}
    end
  end

  @spec execution_surface(t()) :: ExecutionSurface.t()
  def execution_surface(%__MODULE__{} = options) do
    {:ok, execution_surface} =
      ExecutionSurface.new(
        surface_kind: options.surface_kind,
        transport_options: options.transport_options,
        target_id: options.target_id,
        lease_ref: options.lease_ref,
        surface_ref: options.surface_ref,
        boundary_class: options.boundary_class,
        observability: options.observability
      )

    execution_surface
  end

  @spec provider_profile_options(t()) :: keyword()
  def provider_profile_options(%__MODULE__{} = options) do
    Keyword.put(options.provider_options, :execution_surface, execution_surface(options))
  end

  @doc """
  Builds a validated session options struct or raises.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    case new(opts) do
      {:ok, options} -> options
      {:error, reason} -> raise ArgumentError, "invalid session options: #{inspect(reason)}"
    end
  end

  defp validate_profile(nil), do: {:ok, nil}

  defp validate_profile(profile) when is_atom(profile) do
    case ProviderProfile.ensure_module(profile) do
      :ok -> {:ok, profile}
      {:error, _reason} -> {:error, {:invalid_profile, profile}}
    end
  end

  defp validate_profile(profile), do: {:error, {:invalid_profile, profile}}

  defp validate_provider(nil, nil), do: {:error, :missing_provider}

  defp validate_provider(nil, profile) when is_atom(profile) do
    {:ok, profile.id()}
  end

  defp validate_provider(provider, nil) when is_atom(provider), do: {:ok, provider}

  defp validate_provider(provider, profile) when is_atom(provider) and is_atom(profile) do
    profile_provider = profile.id()

    if provider == profile_provider do
      {:ok, provider}
    else
      {:error, {:provider_profile_mismatch, provider, profile_provider}}
    end
  end

  defp validate_provider(provider, _profile), do: {:error, {:invalid_provider, provider}}

  defp validate_registry(registry) when is_pid(registry) or is_atom(registry), do: :ok
  defp validate_registry(registry), do: {:error, {:invalid_registry, registry}}

  defp validate_subscriber(nil), do: :ok
  defp validate_subscriber(pid) when is_pid(pid), do: :ok

  defp validate_subscriber({pid, tag}) when is_pid(pid) and (tag == :legacy or is_reference(tag)),
    do: :ok

  defp validate_subscriber(subscriber), do: {:error, {:invalid_subscriber, subscriber}}

  defp validate_metadata(metadata) when is_map(metadata), do: :ok
  defp validate_metadata(metadata), do: {:error, {:invalid_metadata, metadata}}

  defp validate_session_event_tag(tag) when is_atom(tag), do: :ok
  defp validate_session_event_tag(tag), do: {:error, {:invalid_session_event_tag, tag}}

  defp validate_starter(nil), do: :ok
  defp validate_starter({pid, ref}) when is_pid(pid) and is_reference(ref), do: :ok
  defp validate_starter(starter), do: {:error, {:invalid_starter, starter}}

  defp reject_transport_selector(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :transport_module) do
      {:error, {:unsupported_option, :transport_selector}}
    else
      :ok
    end
  end

  defp reject_public_simulation_selector(opts) when is_list(opts) do
    if Enum.any?(opts, &public_simulation_entry?/1) do
      {:error, {:unsupported_option, :simulation_selector}}
    else
      :ok
    end
  end

  defp public_simulation_entry?({key, _value}), do: key in [:simulation, "simulation"]
  defp public_simulation_entry?(_entry), do: false
end
