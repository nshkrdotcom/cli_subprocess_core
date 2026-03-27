# Shutdown And Timeouts

`CliSubprocessCore.Transport` separates normal shutdown, escalated shutdown,
and timeout behavior so callers can choose the right level of force.

## Normal Close

`close/1` stops the transport `GenServer` with reason `:normal`. During
`terminate/2`, the transport:

1. cancels finalize and headless timers
2. demonitors subscribers
3. replies to pending callers with `transport_stopped`
4. stops the subprocess

Use `close/1` when the caller still owns the transport and wants an orderly
shutdown.

## Force Close

`force_close/1` is the escalation path. The call itself is wrapped in a task so
the caller does not hang forever on an unresponsive transport.

Once the server handles the call, it:

1. invokes `:exec.stop/1`
2. escalates with `:exec.kill(pid, 9)`
3. stops the `GenServer`

If the `GenServer` is wedged or suspended, the caller sees:

```elixir
{:error, {:transport, %CliSubprocessCore.Transport.Error{reason: :timeout}}}
```

The underlying call may still complete later once the server resumes. That is
intentional: caller safety takes priority over synchronous certainty.

## Interrupt

`interrupt/1` sends SIGINT via `:exec.kill(pid, 2)`.

Use it when the subprocess is still healthy but should be asked to abort the
current turn or command without a full force-close.

The resulting exit is surfaced to subscribers as a normalized
`CliSubprocessCore.ProcessExit` struct.

## EOF

`end_input/1` uses the active stdin contract and is the correct way to finish a
half-duplex or EOF-driven subprocess conversation.

- non-PTY transports send `:eof`
- PTY transports send the terminal EOF byte (`Ctrl-D`)

This is separate from `close/1`:

- `end_input/1` tells the child no more stdin is coming
- `close/1` tears down the transport itself

Interrupt and forced shutdown signal the subprocess process group directly from
the core runtime. Startup does not depend on the internal runtime's
`:kill_group` flag.

## Headless Timeout

When a transport has no subscribers, it starts a headless timer. If no
subscriber attaches before `headless_timeout_ms`, the transport stops itself.

This applies both to:

- transports started without a bootstrap subscriber
- transports where the last subscriber unsubscribed or died

Set `headless_timeout_ms: :infinity` to disable this behavior.

## Exit Finalization

Child exits are finalized after a short delay so the transport can:

1. drain any queued stdout lines
2. flush a trailing stdout fragment
3. flush a trailing stderr callback fragment
4. dispatch the exit event

That finalize step avoids losing late stdout/stderr chunks that arrive around
process exit.

## Safe Calls

Public APIs such as `send/2`, `end_input/1`, `interrupt/1`, and `force_close/1`
use `TaskSupport.async_nolink/2` plus the `Task.yield || Task.shutdown`
pattern. This gives the caller bounded wait behavior even if the transport is
blocked, dead, or mid-shutdown.

Normalized call-time failures include:

- `:not_connected`
- `:timeout`
- `:transport_stopped`
- `{:call_exit, reason}`
- `{:send_failed, reason}`

All of them are wrapped in `CliSubprocessCore.Transport.Error`.
