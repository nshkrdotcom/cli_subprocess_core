# Event And Payload Model

The normalized runtime vocabulary in `CliSubprocessCore` is the source of truth
for provider CLI execution events.

## Schema Ownership And Forward Compatibility

`Zoi` is the canonical validation and normalization layer for new dynamic maps
that enter the common runtime vocabulary.

- `CliSubprocessCore.Event` and every `CliSubprocessCore.Payload.*` module own a
  `schema/0`, `parse/1`, `parse!/1`, and `to_map/1` boundary.
- The public contract remains the event or payload struct, not an anonymous
  parsed map.
- Forward-compatible common-lane fields are preserved with
  `Zoi.map(..., unrecognized_keys: :preserve)` and projected into each
  struct's `extra` field.
- Provider-native detail that does not belong in the normalized vocabulary
  should stay in `event.raw` or in the provider repo that owns the richer
  schema.

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
  metadata: %{},
  extra: %{}
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
- `extra`: preserved future-compatible event keys that are not part of the
  stable shared envelope yet

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

Every payload struct also preserves forward-compatible unknown keys in its own
`extra` field when the boundary is intentionally map-backed and evolving.

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
