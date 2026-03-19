defmodule CliSubprocessCore.Runtime do
  @moduledoc """
  Runtime state helpers for normalized session event emission.
  """

  alias CliSubprocessCore.{Event, Payload, ProviderProfile}

  defstruct provider: nil,
            profile: nil,
            provider_session_id: nil,
            sequence: 0,
            metadata: %{}

  @type t :: %__MODULE__{
          provider: atom(),
          profile: module(),
          provider_session_id: String.t() | nil,
          sequence: non_neg_integer(),
          metadata: map()
        }

  @doc """
  Creates a new runtime state.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    profile = Keyword.fetch!(opts, :profile)
    :ok = ensure_valid_profile!(profile)

    provider = Keyword.get_lazy(opts, :provider, fn -> profile.id() end)

    %__MODULE__{
      provider: provider,
      profile: profile,
      provider_session_id: Keyword.get(opts, :provider_session_id),
      sequence: Keyword.get(opts, :sequence, 0),
      metadata: Payload.normalize_metadata(Keyword.get(opts, :metadata, %{}))
    }
  end

  @doc """
  Emits the next normalized event and increments the runtime sequence.
  """
  @spec next_event(t(), Event.kind(), Event.payload(), keyword()) :: {Event.t(), t()}
  def next_event(%__MODULE__{} = runtime, kind, payload, opts \\ []) when is_list(opts) do
    next_sequence = runtime.sequence + 1

    event =
      Event.new(kind,
        provider: runtime.provider,
        sequence: next_sequence,
        payload: payload,
        raw: Keyword.get(opts, :raw),
        provider_session_id: Keyword.get(opts, :provider_session_id, runtime.provider_session_id),
        metadata:
          Map.merge(
            runtime.metadata,
            Payload.normalize_metadata(Keyword.get(opts, :metadata, %{}))
          )
      )

    {event, %{runtime | sequence: next_sequence}}
  end

  @doc """
  Replaces the provider session identifier tracked by the runtime.
  """
  @spec put_provider_session_id(t(), String.t() | nil) :: t()
  def put_provider_session_id(%__MODULE__{} = runtime, provider_session_id) do
    %{runtime | provider_session_id: provider_session_id}
  end

  @doc """
  Stores a single metadata key on the runtime state.
  """
  @spec put_metadata(t(), atom() | String.t(), term()) :: t()
  def put_metadata(%__MODULE__{} = runtime, key, value) do
    %{runtime | metadata: Map.put(runtime.metadata, key, value)}
  end

  @doc """
  Returns runtime metadata for observability and session inspection.
  """
  @spec info(t()) :: map()
  def info(%__MODULE__{} = runtime) do
    %{
      metadata: runtime.metadata,
      profile: runtime.profile,
      provider: runtime.provider,
      provider_session_id: runtime.provider_session_id,
      sequence: runtime.sequence
    }
  end

  defp ensure_valid_profile!(profile) do
    case ProviderProfile.ensure_module(profile) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid provider profile: #{inspect(reason)}"
    end
  end
end
