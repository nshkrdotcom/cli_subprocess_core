defmodule CliSubprocessCore.Event do
  @moduledoc """
  Normalized runtime event envelope emitted by the core session layer.
  """

  alias CliSubprocessCore.Payload

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

  defstruct [
    :id,
    :kind,
    :provider,
    :sequence,
    :timestamp,
    :payload,
    :raw,
    :provider_session_id,
    metadata: %{}
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
          metadata: map()
        }

  @doc """
  Returns the supported normalized event kinds in stable order.
  """
  @spec kinds() :: nonempty_list(kind())
  def kinds, do: @kinds

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
  Builds a normalized runtime event.
  """
  @spec new(kind(), keyword() | map()) :: t()
  def new(kind, attrs \\ []) when is_list(attrs) or is_map(attrs) do
    unless valid_kind?(kind) do
      raise ArgumentError, "unsupported event kind: #{inspect(kind)}"
    end

    attrs = Enum.into(attrs, %{})
    payload = build_payload(kind, Map.get(attrs, :payload))

    %__MODULE__{
      id: Map.get(attrs, :id, System.unique_integer([:positive, :monotonic])),
      kind: kind,
      provider: Map.get(attrs, :provider),
      sequence: Map.get(attrs, :sequence),
      timestamp: Map.get(attrs, :timestamp, DateTime.utc_now()),
      payload: payload,
      raw: Map.get(attrs, :raw),
      provider_session_id: Map.get(attrs, :provider_session_id),
      metadata: Payload.normalize_metadata(Map.get(attrs, :metadata, %{}))
    }
  end

  defp build_payload(kind, nil) do
    payload_module(kind).new()
  end

  defp build_payload(kind, payload) do
    module = payload_module(kind)

    if is_struct(payload, module) do
      payload
    else
      raise ArgumentError,
            "payload for #{inspect(kind)} must be a #{inspect(module)} struct, got: #{inspect(payload)}"
    end
  end
end
