defmodule CliSubprocessCore.RuntimeTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.{Payload, Runtime}
  alias CliSubprocessCore.TestSupport.ProviderProfiles.Echo

  test "tracks runtime state and emits normalized events" do
    runtime =
      Runtime.new(
        provider: :echo,
        profile: Echo,
        provider_session_id: "provider-session-1",
        metadata: %{lane: :core}
      )

    assert Runtime.info(runtime) == %{
             metadata: %{lane: :core},
             profile: Echo,
             provider: :echo,
             provider_session_id: "provider-session-1",
             sequence: 0
           }

    {event, runtime} =
      Runtime.next_event(
        runtime,
        :assistant_delta,
        Payload.AssistantDelta.new(content: "partial"),
        raw: %{"delta" => "partial"}
      )

    assert event.kind == :assistant_delta
    assert event.provider == :echo
    assert event.sequence == 1
    assert event.provider_session_id == "provider-session-1"
    assert event.metadata == %{lane: :core}
    assert event.raw == %{"delta" => "partial"}

    runtime = Runtime.put_provider_session_id(runtime, "provider-session-2")
    runtime = Runtime.put_metadata(runtime, :request_id, "req-1")

    {event, runtime} =
      Runtime.next_event(
        runtime,
        :result,
        Payload.Result.new(status: :completed, stop_reason: :done)
      )

    assert event.sequence == 2
    assert event.provider_session_id == "provider-session-2"
    assert event.metadata == %{lane: :core, request_id: "req-1"}
    assert runtime.sequence == 2
  end
end
