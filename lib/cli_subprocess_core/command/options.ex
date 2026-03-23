defmodule CliSubprocessCore.Command.Options do
  @moduledoc """
  Validated command-lane options for provider-aware one-shot execution.
  """

  alias CliSubprocessCore.{Command, ProviderProfile, ProviderRegistry, Transport}
  alias CliSubprocessCore.Transport.RunOptions

  @default_registry ProviderRegistry
  @default_transport_module Transport
  @reserved_keys [
    :provider,
    :profile,
    :registry,
    :transport_module,
    :stdin,
    :timeout,
    :stderr,
    :close_stdin
  ]

  defstruct invocation: nil,
            provider: nil,
            profile: nil,
            registry: @default_registry,
            transport_module: @default_transport_module,
            stdin: nil,
            timeout: RunOptions.default_timeout_ms(),
            stderr: :separate,
            close_stdin: true,
            provider_options: []

  @type t :: %__MODULE__{
          invocation: Command.t() | nil,
          provider: atom() | nil,
          profile: module() | nil,
          registry: pid() | atom(),
          transport_module: module(),
          stdin: term(),
          timeout: timeout(),
          stderr: RunOptions.stderr_mode(),
          close_stdin: boolean(),
          provider_options: keyword()
        }

  @type validation_error ::
          :missing_provider
          | {:invalid_command, term()}
          | {:invalid_args, term()}
          | {:invalid_cwd, term()}
          | {:invalid_env, term()}
          | {:invalid_provider, term()}
          | {:invalid_profile, term()}
          | {:provider_profile_mismatch, atom(), atom()}
          | {:invalid_registry, term()}
          | {:invalid_transport_module, term()}
          | {:invalid_timeout, term()}
          | {:invalid_stderr, term()}
          | {:invalid_close_stdin, term()}

  @doc """
  Builds validated command-lane options around a normalized invocation.
  """
  @spec new(Command.t(), keyword()) :: {:ok, t()} | {:error, validation_error()}
  def new(%Command{} = invocation, opts) when is_list(opts) do
    with :ok <- validate_invocation(invocation),
         :ok <-
           validate_transport_module(
             Keyword.get(opts, :transport_module, @default_transport_module)
           ),
         {:ok, run_options} <- RunOptions.new(invocation, opts) do
      {:ok,
       %__MODULE__{
         invocation: invocation,
         transport_module: Keyword.get(opts, :transport_module, @default_transport_module),
         stdin: run_options.stdin,
         timeout: run_options.timeout,
         stderr: run_options.stderr,
         close_stdin: run_options.close_stdin
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
         :ok <-
           validate_transport_module(
             Keyword.get(opts, :transport_module, @default_transport_module)
           ),
         :ok <- validate_timeout(Keyword.get(opts, :timeout, RunOptions.default_timeout_ms())),
         :ok <- validate_stderr(Keyword.get(opts, :stderr, :separate)),
         :ok <- validate_close_stdin(Keyword.get(opts, :close_stdin, true)) do
      {:ok,
       %__MODULE__{
         provider: provider,
         profile: profile,
         registry: Keyword.get(opts, :registry, @default_registry),
         transport_module: Keyword.get(opts, :transport_module, @default_transport_module),
         stdin: Keyword.get(opts, :stdin),
         timeout: Keyword.get(opts, :timeout, RunOptions.default_timeout_ms()),
         stderr: Keyword.get(opts, :stderr, :separate),
         close_stdin: Keyword.get(opts, :close_stdin, true),
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

  defp validate_transport_module(module) when is_atom(module) do
    callbacks = [{:run, 2}]

    if Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end) do
      :ok
    else
      {:error, {:invalid_transport_module, module}}
    end
  end

  defp validate_transport_module(module), do: {:error, {:invalid_transport_module, module}}

  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: :ok
  defp validate_timeout(timeout), do: {:error, {:invalid_timeout, timeout}}

  defp validate_stderr(mode) when mode in [:separate, :stdout], do: :ok
  defp validate_stderr(mode), do: {:error, {:invalid_stderr, mode}}

  defp validate_close_stdin(value) when is_boolean(value), do: :ok
  defp validate_close_stdin(value), do: {:error, {:invalid_close_stdin, value}}
end
