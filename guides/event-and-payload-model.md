# Event And Payload Model

This guide lives at `/home/home/p/g/n/cli_subprocess_core/guides/event-and-payload-model.md`.

The normalized runtime vocabulary in `/home/home/p/g/n/cli_subprocess_core`
is the source of truth for provider CLI execution events.

## Event Envelope

`CliSubprocessCore.Event` is the common envelope emitted by the shared runtime.

```elixir
%CliSubprocessCore.Event{
  id: 1,
  kind: :assistant_delta,
  provider: :codex,
  sequence: 42,
  timestamp: ~U[2026-03-19 00:00:00Z],
  payload: %CliSubprocessCore.Payload.AssistantDelta{},
  raw: nil,
  provider_session_id: "provider-session-1",
  metadata: %{}
}
```

Field meanings:

- `id`: local unique event id
- `kind`: normalized runtime kind
- `provider`: normalized provider id
- `sequence`: per-session event ordering
- `timestamp`: event creation timestamp
- `payload`: normalized payload struct for the given kind
- `raw`: optional provider-native data retained for debugging
- `provider_session_id`: provider-assigned session identifier when available
- `metadata`: runtime-owned metadata

## Normalized Kinds

The foundation currently defines these kinds:

- `:run_started`
- `:assistant_delta`
- `:assistant_message`
- `:user_message`
- `:thinking`
- `:tool_use`
- `:tool_result`
- `:approval_requested`
- `:approval_resolved`
- `:cost_update`
- `:result`
- `:error`
- `:stderr`
- `:raw`

Each kind maps to a payload module:

| Kind | Payload |
| --- | --- |
| `:run_started` | `CliSubprocessCore.Payload.RunStarted` |
| `:assistant_delta` | `CliSubprocessCore.Payload.AssistantDelta` |
| `:assistant_message` | `CliSubprocessCore.Payload.AssistantMessage` |
| `:user_message` | `CliSubprocessCore.Payload.UserMessage` |
| `:thinking` | `CliSubprocessCore.Payload.Thinking` |
| `:tool_use` | `CliSubprocessCore.Payload.ToolUse` |
| `:tool_result` | `CliSubprocessCore.Payload.ToolResult` |
| `:approval_requested` | `CliSubprocessCore.Payload.ApprovalRequested` |
| `:approval_resolved` | `CliSubprocessCore.Payload.ApprovalResolved` |
| `:cost_update` | `CliSubprocessCore.Payload.CostUpdate` |
| `:result` | `CliSubprocessCore.Payload.Result` |
| `:error` | `CliSubprocessCore.Payload.Error` |
| `:stderr` | `CliSubprocessCore.Payload.Stderr` |
| `:raw` | `CliSubprocessCore.Payload.Raw` |

## Payload Families

The payload structs intentionally separate shared runtime semantics from any
provider-native output shape.

Common examples:

- `CliSubprocessCore.Payload.AssistantDelta` holds streamed assistant text.
- `CliSubprocessCore.Payload.ToolUse` and
  `CliSubprocessCore.Payload.ToolResult` represent tool invocation semantics.
- `CliSubprocessCore.Payload.ApprovalRequested` and
  `CliSubprocessCore.Payload.ApprovalResolved` represent human approval flow.
- `CliSubprocessCore.Payload.CostUpdate` carries token and cost accounting.
- `CliSubprocessCore.Payload.Raw` retains unnormalized material when a provider
  event does not map cleanly to a richer normalized struct yet.

## Example

```elixir
payload =
  CliSubprocessCore.Payload.ToolUse.new(
    tool_name: "shell",
    tool_call_id: "tool-1",
    input: %{"cmd" => "pwd"}
  )

event =
  CliSubprocessCore.Event.new(
    :tool_use,
    provider: :codex,
    sequence: 10,
    payload: payload,
    provider_session_id: "provider-session-1"
  )
```

The event and payload model is intended to be stable enough for:

- the future core session engine
- first-party SDK projections
- ASM run envelopes that wrap, rather than redefine, the runtime vocabulary
