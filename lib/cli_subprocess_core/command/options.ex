defmodule CliSubprocessCore.Command.Options do
  @moduledoc """
  Validated command-lane options for provider-aware one-shot execution.
  """

  alias CliSubprocessCore.{
    Command,
    ExecutionSurface,
    GovernedAuthority,
    ProviderProfile,
    ProviderRegistry,
    ProviderRuntimeProfile
  }

  @default_registry ProviderRegistry
  @default_timeout_ms 30_000
  @reserved_keys [
    :provider,
    :profile,
    :registry,
    :stdin,
    :timeout,
    :stderr,
    :close_stdin,
    :execution_surface,
    :surface_kind,
    :transport_options,
    :target_id,
    :lease_ref,
    :surface_ref,
    :boundary_class,
    :observability,
    :governed_authority
  ]
  @governed_smuggling_keys [
    :command,
    :executable,
    :command_spec,
    :cli_path,
    :path_to_claude_code_executable,
    :cwd,
    :env,
    :clear_env?,
    :clear_env,
    :config_root,
    :auth_root,
    :base_url,
    :ollama_base_url,
    :anthropic_base_url,
    :codex_oss_base_url,
    :config_values,
    :provider_runtime_profile_ref
  ]

  defstruct invocation: nil,
            provider: nil,
            profile: nil,
            registry: @default_registry,
            stdin: nil,
            timeout: @default_timeout_ms,
            stderr: :separate,
            close_stdin: true,
            surface_kind: ExecutionSurface.default_surface_kind(),
            transport_options: [],
            target_id: nil,
            lease_ref: nil,
            surface_ref: nil,
            boundary_class: nil,
            observability: %{},
            governed_authority: nil,
            provider_options: []

  @type t :: %__MODULE__{
          invocation: Command.t() | nil,
          provider: atom() | nil,
          profile: module() | nil,
          registry: pid() | atom(),
          stdin: term(),
          timeout: timeout(),
          stderr: stderr_mode(),
          close_stdin: boolean(),
          surface_kind: atom(),
          transport_options: keyword(),
          target_id: String.t() | nil,
          lease_ref: String.t() | nil,
          surface_ref: String.t() | nil,
          boundary_class: atom() | String.t() | nil,
          observability: map(),
          governed_authority: GovernedAuthority.t() | nil,
          provider_options: keyword()
        }

  @type stderr_mode :: :separate | :stdout

  @type validation_error ::
          :missing_provider
          | {:invalid_command, term()}
          | {:invalid_args, term()}
          | {:invalid_cwd, term()}
          | {:invalid_env, term()}
          | {:invalid_clear_env, term()}
          | {:invalid_user, term()}
          | {:invalid_provider, term()}
          | {:invalid_profile, term()}
          | {:provider_profile_mismatch, atom(), atom()}
          | {:invalid_registry, term()}
          | {:unsupported_option, :transport_selector}
          | {:unsupported_option, :simulation_selector}
          | {:invalid_timeout, term()}
          | {:invalid_stderr, term()}
          | {:invalid_close_stdin, term()}
          | {:invalid_surface_kind, term()}
          | {:invalid_transport_options, term()}
          | {:invalid_target_id, term()}
          | {:invalid_lease_ref, term()}
          | {:invalid_surface_ref, term()}
          | {:invalid_boundary_class, term()}
          | {:invalid_observability, term()}
          | GovernedAuthority.validation_error()
          | {:governed_launch_smuggling, atom()}
          | {:governed_launch_smuggling, atom(), term()}
          | ProviderRuntimeProfile.resolve_error()

  @doc """
  Builds validated command-lane options around a normalized invocation.
  """
  @spec new(Command.t(), keyword()) :: {:ok, t()} | {:error, validation_error()}
  def new(%Command{} = invocation, opts) when is_list(opts) do
    with :ok <- validate_invocation(invocation),
         {:ok, governed_authority} <-
           GovernedAuthority.new(Keyword.get(opts, :governed_authority)),
         :ok <- GovernedAuthority.enforce_invocation(invocation, governed_authority),
         :ok <- reject_transport_selector(opts),
         :ok <- reject_public_simulation_selector(opts),
         {:ok, execution_surface} <- ExecutionSurface.new(opts),
         :ok <- validate_timeout(Keyword.get(opts, :timeout, @default_timeout_ms)),
         :ok <- validate_stderr(Keyword.get(opts, :stderr, :separate)),
         :ok <- validate_close_stdin(Keyword.get(opts, :close_stdin, true)) do
      {:ok,
       %__MODULE__{
         invocation: invocation,
         stdin: Keyword.get(opts, :stdin),
         timeout: Keyword.get(opts, :timeout, @default_timeout_ms),
         stderr: Keyword.get(opts, :stderr, :separate),
         close_stdin: Keyword.get(opts, :close_stdin, true),
         surface_kind: execution_surface.surface_kind,
         transport_options: execution_surface.transport_options,
         target_id: execution_surface.target_id,
         lease_ref: execution_surface.lease_ref,
         surface_ref: execution_surface.surface_ref,
         boundary_class: execution_surface.boundary_class,
         observability: execution_surface.observability,
         governed_authority: governed_authority
       }}
    else
      {:error, {:invalid_run_options, reason}} -> {:error, reason}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Builds validated provider-aware command-lane options.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, validation_error()}
  def new(opts) when is_list(opts) do
    provider_options = Keyword.drop(opts, @reserved_keys)
    profile = Keyword.get(opts, :profile)

    with {:ok, governed_authority} <-
           GovernedAuthority.new(Keyword.get(opts, :governed_authority)),
         :ok <- reject_governed_smuggling(provider_options, governed_authority),
         {:ok, profile} <- validate_profile(profile),
         {:ok, provider} <- validate_provider(Keyword.get(opts, :provider), profile),
         :ok <- validate_registry(Keyword.get(opts, :registry, @default_registry)),
         :ok <- reject_transport_selector(opts),
         :ok <- reject_public_simulation_selector(opts),
         {:ok, execution_surface} <- ExecutionSurface.new(opts),
         {:ok, {provider_options, execution_surface}} <-
           resolve_provider_runtime_profile(
             provider,
             provider_options,
             execution_surface,
             governed_authority
           ),
         :ok <- validate_timeout(Keyword.get(opts, :timeout, @default_timeout_ms)),
         :ok <- validate_stderr(Keyword.get(opts, :stderr, :separate)),
         :ok <- validate_close_stdin(Keyword.get(opts, :close_stdin, true)) do
      {:ok,
       %__MODULE__{
         provider: provider,
         profile: profile,
         registry: Keyword.get(opts, :registry, @default_registry),
         stdin: Keyword.get(opts, :stdin),
         timeout: Keyword.get(opts, :timeout, @default_timeout_ms),
         stderr: Keyword.get(opts, :stderr, :separate),
         close_stdin: Keyword.get(opts, :close_stdin, true),
         surface_kind: execution_surface.surface_kind,
         transport_options: execution_surface.transport_options,
         target_id: execution_surface.target_id,
         lease_ref: execution_surface.lease_ref,
         surface_ref: execution_surface.surface_ref,
         boundary_class: execution_surface.boundary_class,
         observability: execution_surface.observability,
         governed_authority: governed_authority,
         provider_options: provider_options
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

  @spec runtime_execution_surface(t()) :: struct()
  def runtime_execution_surface(%__MODULE__{} = options) do
    options
    |> execution_surface()
    |> ExecutionSurface.to_runtime_surface()
  end

  @spec provider_profile_options(t()) :: keyword()
  def provider_profile_options(%__MODULE__{} = options) do
    provider_options =
      case options.governed_authority do
        nil ->
          options.provider_options

        %GovernedAuthority{} = authority ->
          Keyword.put(options.provider_options, :governed_authority, authority)
      end

    Keyword.put(provider_options, :execution_surface, execution_surface(options))
  end

  defp validate_invocation(%Command{} = invocation) do
    Command.validate(invocation)
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
  defp validate_provider(nil, profile) when is_atom(profile), do: {:ok, profile.id()}
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

  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: :ok
  defp validate_timeout(timeout), do: {:error, {:invalid_timeout, timeout}}

  defp validate_stderr(mode) when mode in [:separate, :stdout], do: :ok
  defp validate_stderr(mode), do: {:error, {:invalid_stderr, mode}}

  defp validate_close_stdin(value) when is_boolean(value), do: :ok
  defp validate_close_stdin(value), do: {:error, {:invalid_close_stdin, value}}

  defp resolve_provider_runtime_profile(provider, provider_options, execution_surface, nil) do
    ProviderRuntimeProfile.resolve(provider, provider_options, execution_surface)
  end

  defp resolve_provider_runtime_profile(
         _provider,
         provider_options,
         execution_surface,
         %GovernedAuthority{}
       ) do
    {:ok, {provider_options, execution_surface}}
  end

  defp reject_governed_smuggling(_provider_options, nil), do: :ok

  defp reject_governed_smuggling(provider_options, %GovernedAuthority{}) do
    cond do
      key = first_present_key(provider_options, @governed_smuggling_keys) ->
        {:error, {:governed_launch_smuggling, key}}

      model_payload_env_overrides?(Keyword.get(provider_options, :model_payload)) ->
        {:error, {:governed_launch_smuggling, :model_payload, :env_overrides}}

      model_payload_backend_config?(Keyword.get(provider_options, :model_payload)) ->
        {:error, {:governed_launch_smuggling, :model_payload, :backend_metadata}}

      true ->
        :ok
    end
  end

  defp first_present_key(provider_options, keys) do
    Enum.find(keys, fn key -> Keyword.has_key?(provider_options, key) end)
  end

  defp model_payload_env_overrides?(payload) when is_map(payload) do
    case payload_value(payload, :env_overrides) do
      value when is_map(value) -> map_size(value) > 0
      _other -> false
    end
  end

  defp model_payload_env_overrides?(_payload), do: false

  defp model_payload_backend_config?(payload) when is_map(payload) do
    case payload_value(payload, :backend_metadata) do
      value when is_map(value) ->
        value_has_nonempty_key?(value, "config_values") or
          value_has_nonempty_key?(value, "oss_provider") or
          value_has_nonempty_key?(value, "external_model")

      _other ->
        false
    end
  end

  defp model_payload_backend_config?(_payload), do: false

  defp value_has_nonempty_key?(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key, payload_value(map, payload_backend_key(key))) do
      nil -> false
      "" -> false
      [] -> false
      %{} = value -> map_size(value) > 0
      _other -> true
    end
  end

  defp payload_backend_key("config_values"), do: :config_values
  defp payload_backend_key("oss_provider"), do: :oss_provider
  defp payload_backend_key("external_model"), do: :external_model

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
  end

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
