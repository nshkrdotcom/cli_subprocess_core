defmodule CliSubprocessCore.Command.Options do
  @moduledoc """
  Validated command-lane options for provider-aware one-shot execution.
  """

  alias CliSubprocessCore.{Command, ProviderProfile, ProviderRegistry, Transport}
  alias CliSubprocessCore.Transport.ExecutionSurface
  alias CliSubprocessCore.Transport.RunOptions

  @default_registry ProviderRegistry
  @reserved_keys [
    :provider,
    :profile,
    :registry,
    :stdin,
    :timeout,
    :stderr,
    :close_stdin,
    :surface_kind,
    :transport_options,
    :target_id,
    :lease_ref,
    :surface_ref,
    :boundary_class,
    :observability
  ]

  defstruct invocation: nil,
            provider: nil,
            profile: nil,
            registry: @default_registry,
            stdin: nil,
            timeout: RunOptions.default_timeout_ms(),
            stderr: :separate,
            close_stdin: true,
            surface_kind: ExecutionSurface.default_surface_kind(),
            transport_options: [],
            target_id: nil,
            lease_ref: nil,
            surface_ref: nil,
            boundary_class: nil,
            observability: %{},
            provider_options: []

  @type t :: %__MODULE__{
          invocation: Command.t() | nil,
          provider: atom() | nil,
          profile: module() | nil,
          registry: pid() | atom(),
          stdin: term(),
          timeout: timeout(),
          stderr: RunOptions.stderr_mode(),
          close_stdin: boolean(),
          surface_kind: Transport.surface_kind(),
          transport_options: keyword(),
          target_id: String.t() | nil,
          lease_ref: String.t() | nil,
          surface_ref: String.t() | nil,
          boundary_class: atom() | nil,
          observability: map(),
          provider_options: keyword()
        }

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

  @doc """
  Builds validated command-lane options around a normalized invocation.
  """
  @spec new(Command.t(), keyword()) :: {:ok, t()} | {:error, validation_error()}
  def new(%Command{} = invocation, opts) when is_list(opts) do
    with :ok <- validate_invocation(invocation),
         :ok <- reject_transport_selector(opts),
         {:ok, execution_surface} <- ExecutionSurface.new(opts),
         {:ok, run_options} <- RunOptions.new(invocation, opts) do
      {:ok,
       %__MODULE__{
         invocation: invocation,
         stdin: run_options.stdin,
         timeout: run_options.timeout,
         stderr: run_options.stderr,
         close_stdin: run_options.close_stdin,
         surface_kind: execution_surface.surface_kind,
         transport_options: execution_surface.transport_options,
         target_id: execution_surface.target_id,
         lease_ref: execution_surface.lease_ref,
         surface_ref: execution_surface.surface_ref,
         boundary_class: execution_surface.boundary_class,
         observability: execution_surface.observability
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

    with {:ok, profile} <- validate_profile(profile),
         {:ok, provider} <- validate_provider(Keyword.get(opts, :provider), profile),
         :ok <- validate_registry(Keyword.get(opts, :registry, @default_registry)),
         :ok <- reject_transport_selector(opts),
         {:ok, execution_surface} <- ExecutionSurface.new(opts),
         :ok <- validate_timeout(Keyword.get(opts, :timeout, RunOptions.default_timeout_ms())),
         :ok <- validate_stderr(Keyword.get(opts, :stderr, :separate)),
         :ok <- validate_close_stdin(Keyword.get(opts, :close_stdin, true)) do
      {:ok,
       %__MODULE__{
         provider: provider,
         profile: profile,
         registry: Keyword.get(opts, :registry, @default_registry),
         stdin: Keyword.get(opts, :stdin),
         timeout: Keyword.get(opts, :timeout, RunOptions.default_timeout_ms()),
         stderr: Keyword.get(opts, :stderr, :separate),
         close_stdin: Keyword.get(opts, :close_stdin, true),
         surface_kind: execution_surface.surface_kind,
         transport_options: execution_surface.transport_options,
         target_id: execution_surface.target_id,
         lease_ref: execution_surface.lease_ref,
         surface_ref: execution_surface.surface_ref,
         boundary_class: execution_surface.boundary_class,
         observability: execution_surface.observability,
         provider_options: provider_options
       }}
    end
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

  defp reject_transport_selector(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :transport_module) do
      {:error, {:unsupported_option, :transport_selector}}
    else
      :ok
    end
  end
end
