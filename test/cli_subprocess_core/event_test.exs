defmodule CliSubprocessCore.EventTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Event
  alias CliSubprocessCore.Payload

  test "lists the normalized runtime kinds in stable order" do
    assert Event.kinds() == [
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
  end

  test "builds an event with defaults" do
    payload = Payload.AssistantDelta.new(content: "partial")

    event =
      Event.new(:assistant_delta,
        provider: :codex,
        sequence: 7,
        payload: payload,
        provider_session_id: "session-1",
        metadata: %{lane: :core}
      )

    assert %Event{
             kind: :assistant_delta,
             provider: :codex,
             sequence: 7,
             payload: ^payload,
             provider_session_id: "session-1",
             metadata: %{lane: :core}
           } = event

    assert is_integer(event.id)
    assert %DateTime{} = event.timestamp
  end

  test "maps kinds to payload modules" do
    assert Event.payload_module(:run_started) == Payload.RunStarted
    assert Event.payload_module(:assistant_delta) == Payload.AssistantDelta
    assert Event.payload_module(:assistant_message) == Payload.AssistantMessage
    assert Event.payload_module(:user_message) == Payload.UserMessage
    assert Event.payload_module(:thinking) == Payload.Thinking
    assert Event.payload_module(:tool_use) == Payload.ToolUse
    assert Event.payload_module(:tool_result) == Payload.ToolResult
    assert Event.payload_module(:approval_requested) == Payload.ApprovalRequested
    assert Event.payload_module(:approval_resolved) == Payload.ApprovalResolved
    assert Event.payload_module(:cost_update) == Payload.CostUpdate
    assert Event.payload_module(:result) == Payload.Result
    assert Event.payload_module(:error) == Payload.Error
    assert Event.payload_module(:stderr) == Payload.Stderr
    assert Event.payload_module(:raw) == Payload.Raw
  end

  test "rejects unknown kinds" do
    assert_raise ArgumentError, fn ->
      Event.new(:unknown_kind, provider: :codex)
    end
  end
end
