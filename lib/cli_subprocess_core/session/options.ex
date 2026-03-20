defmodule CliSubprocessCore.Session.Options do
  @moduledoc """
  Validated startup options for the common session engine.
  """

  alias CliSubprocessCore.{ProviderProfile, ProviderRegistry, Transport}

  @default_registry ProviderRegistry
  @default_session_event_tag :cli_subprocess_core_session
  @default_transport_module Transport
  @reserved_keys [
    :provider,
    :profile,
    :registry,
    :transport_module,
    :subscriber,
    :metadata,
    :session_event_tag,
    :starter
  ]

  defstruct provider: nil,
            profile: nil,
            registry: @default_registry,
            transport_module: @default_transport_module,
            subscriber: nil,
            metadata: %{},
            session_event_tag: @default_session_event_tag,
            provider_options: [],
            starter: nil

  @type subscriber :: pid() | {pid(), :legacy | reference()} | nil

  @type t :: %__MODULE__{
          provider: atom(),
          profile: module() | nil,
          registry: pid() | atom(),
          transport_module: module(),
          subscriber: subscriber(),
          metadata: map(),
          session_event_tag: atom(),
          provider_options: keyword(),
          starter: {pid(), reference()} | nil
        }

  @type validation_error ::
          :missing_provider
          | {:invalid_provider, term()}
          | {:invalid_profile, term()}
          | {:provider_profile_mismatch, atom(), atom()}
          | {:invalid_registry, term()}
          | {:invalid_transport_module, term()}
          | {:invalid_subscriber, term()}
          | {:invalid_metadata, term()}
          | {:invalid_session_event_tag, term()}
          | {:invalid_starter, term()}

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
         :ok <-
           validate_transport_module(
             Keyword.get(opts, :transport_module, @default_transport_module)
           ),
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
         transport_module: Keyword.get(opts, :transport_module, @default_transport_module),
         subscriber: Keyword.get(opts, :subscriber),
         metadata: Keyword.get(opts, :metadata, %{}),
         session_event_tag: Keyword.get(opts, :session_event_tag, @default_session_event_tag),
         provider_options: provider_options,
         starter: Keyword.get(opts, :starter)
       }}
    end
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

  defp validate_transport_module(module) when is_atom(module) do
    callbacks = [
      {:start, 1},
      {:send, 2},
      {:end_input, 1},
      {:interrupt, 1},
      {:close, 1},
      {:subscribe, 3},
      {:unsubscribe, 2},
      {:status, 1},
      {:stderr, 1}
    ]

    if Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end) do
      :ok
    else
      {:error, {:invalid_transport_module, module}}
    end
  end

  defp validate_transport_module(module), do: {:error, {:invalid_transport_module, module}}

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
end
