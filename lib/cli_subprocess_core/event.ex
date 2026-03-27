defmodule CliSubprocessCore.Event do
  @moduledoc """
  Normalized runtime event envelope emitted by the core session layer.
  """

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.Schema
  alias CliSubprocessCore.Schema.Conventions

  @kinds [
    :run_started,
    :assistant_delta,
    :assistant_message,
    :user_message,
    :thinking,
    :tool_use,
    :tool_result,
    :approval_requested,
    :approval_resolved,
    :cost_update,
    :result,
    :error,
    :stderr,
    :raw
  ]

  @payload_modules %{
    run_started: Payload.RunStarted,
    assistant_delta: Payload.AssistantDelta,
    assistant_message: Payload.AssistantMessage,
    user_message: Payload.UserMessage,
    thinking: Payload.Thinking,
    tool_use: Payload.ToolUse,
    tool_result: Payload.ToolResult,
    approval_requested: Payload.ApprovalRequested,
    approval_resolved: Payload.ApprovalResolved,
    cost_update: Payload.CostUpdate,
    result: Payload.Result,
    error: Payload.Error,
    stderr: Payload.Stderr,
    raw: Payload.Raw
  }

  @known_fields [
    :id,
    :kind,
    :provider,
    :sequence,
    :timestamp,
    :payload,
    :raw,
    :provider_session_id,
    :metadata
  ]
  @schema Zoi.map(
            %{
              id: Zoi.optional(Zoi.nullish(Zoi.integer(gt: 0))),
              kind: Conventions.enum(@kinds),
              provider: Zoi.optional(Zoi.nullish(Zoi.atom())),
              sequence: Zoi.optional(Zoi.nullish(Zoi.integer(gte: 0))),
              timestamp: Zoi.optional(Zoi.nullish(Zoi.datetime(coerce: true))),
              payload: Conventions.optional_any(),
              raw: Conventions.optional_any(),
              provider_session_id: Conventions.optional_trimmed_string(),
              metadata: Conventions.metadata()
            },
            coerce: true,
            unrecognized_keys: :preserve
          )

  defstruct [
    :id,
    :kind,
    :provider,
    :sequence,
    :timestamp,
    :payload,
    :raw,
    :provider_session_id,
    metadata: %{},
    extra: %{}
  ]

  @type kind ::
          :run_started
          | :assistant_delta
          | :assistant_message
          | :user_message
          | :thinking
          | :tool_use
          | :tool_result
          | :approval_requested
          | :approval_resolved
          | :cost_update
          | :result
          | :error
          | :stderr
          | :raw

  @type payload ::
          Payload.RunStarted.t()
          | Payload.AssistantDelta.t()
          | Payload.AssistantMessage.t()
          | Payload.UserMessage.t()
          | Payload.Thinking.t()
          | Payload.ToolUse.t()
          | Payload.ToolResult.t()
          | Payload.ApprovalRequested.t()
          | Payload.ApprovalResolved.t()
          | Payload.CostUpdate.t()
          | Payload.Result.t()
          | Payload.Error.t()
          | Payload.Stderr.t()
          | Payload.Raw.t()

  @type t :: %__MODULE__{
          id: pos_integer(),
          kind: kind(),
          provider: atom() | nil,
          sequence: non_neg_integer() | nil,
          timestamp: DateTime.t(),
          payload: payload(),
          raw: term(),
          provider_session_id: String.t() | nil,
          metadata: map(),
          extra: map()
        }

  @doc """
  Returns the supported normalized event kinds in stable order.
  """
  @spec kinds() :: nonempty_list(kind())
  def kinds, do: @kinds

  @doc """
  Returns the shared event schema for the normalized envelope.
  """
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Returns `true` when the kind is part of the normalized vocabulary.
  """
  @spec valid_kind?(term()) :: boolean()
  def valid_kind?(kind), do: kind in @kinds

  @doc """
  Returns the payload module associated with a normalized kind.
  """
  @spec payload_module(kind()) :: module()
  def payload_module(kind) do
    Map.fetch!(@payload_modules, kind)
  end

  @doc """
  Parses an event envelope through the canonical schema and projects it to the ergonomic struct.
  """
  @spec parse(keyword() | map() | t()) ::
          {:ok, t()}
          | {:error, {:invalid_event, CliSubprocessCore.Schema.error_detail()}}
          | {:error, {:invalid_event_payload, kind(), CliSubprocessCore.Schema.error_detail()}}
  def parse(%__MODULE__{} = event), do: {:ok, event}
  def parse(attrs) when is_list(attrs), do: parse(Enum.into(attrs, %{}))

  def parse(attrs) do
    with {:ok, parsed} <- Schema.parse(@schema, attrs, :invalid_event),
         {:ok, payload} <- build_payload(parsed.kind, Map.get(parsed, :payload)) do
      {known, extra} = Schema.split_extra(parsed, @known_fields)

      {:ok,
       %__MODULE__{
         id: Map.get(known, :id, System.unique_integer([:positive, :monotonic])),
         kind: known.kind,
         provider: Map.get(known, :provider),
         sequence: Map.get(known, :sequence),
         timestamp: Map.get(known, :timestamp, DateTime.utc_now()),
         payload: payload,
         raw: Map.get(known, :raw),
         provider_session_id: Map.get(known, :provider_session_id),
         metadata: Payload.normalize_metadata(Map.get(known, :metadata, %{})),
         extra: extra
       }}
    end
  end

  @doc """
  Parses an event envelope and raises on invalid data.
  """
  @spec parse!(keyword() | map() | t()) :: t()
  def parse!(%__MODULE__{} = event), do: event
  def parse!(attrs) when is_list(attrs), do: parse!(Enum.into(attrs, %{}))

  def parse!(attrs) do
    parsed = Schema.parse!(@schema, attrs, :invalid_event)
    payload = build_payload!(parsed.kind, Map.get(parsed, :payload))
    {known, extra} = Schema.split_extra(parsed, @known_fields)

    %__MODULE__{
      id: Map.get(known, :id, System.unique_integer([:positive, :monotonic])),
      kind: known.kind,
      provider: Map.get(known, :provider),
      sequence: Map.get(known, :sequence),
      timestamp: Map.get(known, :timestamp, DateTime.utc_now()),
      payload: payload,
      raw: Map.get(known, :raw),
      provider_session_id: Map.get(known, :provider_session_id),
      metadata: Payload.normalize_metadata(Map.get(known, :metadata, %{})),
      extra: extra
    }
  end

  @doc """
  Builds a normalized runtime event.
  """
  @spec new(kind(), keyword() | map()) :: t()
  def new(kind, attrs \\ []) when is_list(attrs) or is_map(attrs) do
    unless valid_kind?(kind) do
      raise ArgumentError, "unsupported event kind: #{inspect(kind)}"
    end

    attrs
    |> Enum.into(%{})
    |> Map.put(:kind, kind)
    |> parse!()
  end

  @doc """
  Projects the event back into its normalized map shape, preserving unknown keys.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    event
    |> Schema.to_map(@known_fields)
    |> Map.put(:payload, payload_to_map(event.payload))
  end

  defp build_payload(kind, nil), do: {:ok, payload_module(kind).new()}

  defp build_payload(kind, payload) do
    module = payload_module(kind)

    case module.parse(payload) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, {:invalid_payload, ^module, details}} ->
        {:error, {:invalid_event_payload, kind, details}}
    end
  end

  defp build_payload!(kind, nil), do: payload_module(kind).new()
  defp build_payload!(kind, payload), do: payload_module(kind).parse!(payload)

  defp payload_to_map(payload) when is_atom(payload), do: payload

  defp payload_to_map(%module{} = payload) do
    if function_exported?(module, :to_map, 1) do
      module.to_map(payload)
    else
      Map.from_struct(payload)
    end
  end

  defp payload_to_map(payload), do: payload
end
