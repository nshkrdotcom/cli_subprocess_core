# Shutdown And Timeouts

`cli_subprocess_core` surfaces transport lifecycle behavior through
`CliSubprocessCore.RawSession`, `CliSubprocessCore.Channel`, and
`CliSubprocessCore.Session`.

The lower shutdown, interrupt, timeout, and buffering mechanics are owned by
`ExecutionPlane.Process.Transport` for the covered local session-bearing lane
and for the shared non-local transport surfaces. The core keeps those
semantics visible without re-owning the substrate internals.

## Normal Close

Use `RawSession.stop/1`, `Channel.close/1`, or `Session.close/1` when the
caller still owns the handle and wants an orderly shutdown.

Those entrypoints delegate to the extracted transport and preserve its
transport-owned result/error contract.

## Force Close

`RawSession.force_close/1` and `Channel.force_close/1` expose the escalation
path when the subprocess is unresponsive.

If the underlying transport cannot complete the call within the bounded wait
window, callers see:

```elixir
{:error, {:transport, %ExternalRuntimeTransport.Transport.Error{reason: :timeout}}}
```

That timeout protects the caller from hanging forever while still leaving the
underlying transport free to complete later if it can recover. The surfaced
error struct remains compatibility-shaped even though the active owner is the
Execution Plane transport seam.

## Interrupt

`RawSession.interrupt/1`, `Channel.interrupt/1`, and `Session.interrupt/1`
forward an interrupt request to the substrate according to the configured
transport contract.

The resulting subprocess exit is surfaced as an
`ExternalRuntimeTransport.ProcessExit`.

## EOF

`RawSession.close_input/1`, `Channel.close_input/1`, and `Session.end_input/1`
use the active stdin contract and are the correct way to finish EOF-driven
conversations.

- pipe-backed transports send EOF
- PTY-backed transports send the terminal EOF byte

This is separate from closing the handle itself:

- closing input tells the child no more stdin is coming
- closing the handle tears down the owning session/channel/transport

## Headless Timeout

When the underlying transport has no subscribers, it starts a headless timer.
If nobody attaches before `headless_timeout_ms`, the transport stops itself.

This applies to:

- transports started without a bootstrap subscriber
- transports whose final subscriber unsubscribed or died

Set `headless_timeout_ms: :infinity` to disable the behavior.

## Exit Finalization

The substrate finalizes exits after draining any queued stdout/stderr work so
late fragments are not lost at process shutdown boundaries.

That is why raw-session and channel consumers may still receive final buffered
output immediately before the normalized exit.

## Safe Calls

Transport-facing lifecycle APIs use bounded waits so callers do not hang
forever when the underlying transport is blocked, dead, or mid-shutdown.

Normalized call-time failures still surface as
`ExternalRuntimeTransport.Transport.Error` reasons such as:

- `:not_connected`
- `:timeout`
- `:transport_stopped`
- `{:call_exit, reason}`
- `{:send_failed, reason}`

Those are transport-owned errors carried upward through the core handles as
compatibility projections.
