# Raw Transport

`CliSubprocessCore.Transport` is the provider-agnostic subprocess layer below
the shared command and session APIs. It owns process startup, stdin writes,
stdout dispatch, realtime stderr dispatch, exit normalization, PTY startup,
and shutdown. It is also the only public core layer that exposes lazy startup
directly.

## Public Modules

- `CliSubprocessCore.Transport` – public behaviour and default facade
- `CliSubprocessCore.Transport.Info` – transport metadata snapshot
- `CliSubprocessCore.Transport.Options` – validated startup options
- `CliSubprocessCore.Transport.RunOptions` – validated one-shot execution options
- `CliSubprocessCore.Transport.RunResult` – captured one-shot execution result
- `CliSubprocessCore.Transport.Error` – structured transport failures
- `CliSubprocessCore.RawSession` – provider-agnostic raw-session handle above
  the transport

## Start A Transport

You can pass either a normalized `CliSubprocessCore.Command` or explicit
transport keywords. Above the core, execution-surface input stays generic:

- `:surface_kind` selects the generic execution surface, default
  `:local_subprocess`
- `:transport_options` carries adapter-specific startup settings without
  exposing adapter module names publicly
- `:target_id`, `:lease_ref`, `:surface_ref`, `:boundary_class`, and
  `:observability` carry generic surface metadata into `Transport.Info`

```elixir
command =
  CliSubprocessCore.Command.new("sh", ["-c", "cat"],
    env: %{"TERM" => "xterm-256color"}
  )

ref = make_ref()

{:ok, transport} =
  CliSubprocessCore.Transport.start(
    command: command,
    subscriber: {self(), ref},
    transport_options: [startup_mode: :eager]
  )
```

Supported local-subprocess startup options are normalized by
`CliSubprocessCore.Transport.Options` and can still be passed directly to
`CliSubprocessCore.Transport.start/1` when you are already inside the core:

- `:command` – required executable path or binary name
- `:args` – argv tail
- `:cwd` – working directory
- `:env` – environment map
- `:clear_env?` – whether to clear inherited environment variables first
- `:stdout_mode` – `:line` or `:raw`
- `:stdin_mode` – `:line` or `:raw`
- `:pty?` – whether to request PTY-backed subprocess startup
- `:interrupt_mode` – `:signal` or `{:stdin, payload}`
- `:subscriber` – `pid()` or `{pid(), :legacy | reference()}`
- `:startup_mode` – `:eager` or `:lazy`
- `:task_supervisor` – task supervisor used by safe transport calls
- `:event_tag` – atom used for tagged subscriber events, default `:cli_subprocess_core`
- `:headless_timeout_ms` – no-subscriber auto-stop timeout, default `30_000`
- `:max_buffer_size` – stdout partial-line limit, default `1_048_576`
- `:max_stderr_buffer_size` – stderr ring-buffer limit, default `262_144`
- `:max_buffered_events` – early-event replay buffer size when
  `:buffer_events_until_subscribe?` is enabled, default `128`
- `:stderr_callback` – optional per-line callback for stderr
- `:replay_stderr_on_subscribe?` – replays the retained stderr tail to newly
  attached subscribers, default `false`
- `:buffer_events_until_subscribe?` – buffers stdout/stderr/error events until
  the first subscriber attaches, default `false`

## Event Model

Legacy subscribers receive bare tuples:

- `{:transport_message, line}`
- `{:transport_data, chunk}`
- `{:transport_error, %CliSubprocessCore.Transport.Error{}}`
- `{:transport_stderr, chunk}`
- `{:transport_exit, %CliSubprocessCore.ProcessExit{}}`

Tagged subscribers receive:

- `{event_tag, ref, {:message, line}}`
- `{event_tag, ref, {:data, chunk}}`
- `{event_tag, ref, {:error, %CliSubprocessCore.Transport.Error{}}}`
- `{event_tag, ref, {:stderr, chunk}}`
- `{event_tag, ref, {:exit, %CliSubprocessCore.ProcessExit{}}}`

`event_tag` defaults to `:cli_subprocess_core`, but SDK wrappers can override it
to preserve their historical mailbox shapes while leaving lifecycle ownership
in the core.

Direct adapters should consume tagged delivery through
`CliSubprocessCore.Transport.extract_event/2` rather than hard-coding the
configured outer tag:

```elixir
receive do
  message ->
    case CliSubprocessCore.Transport.extract_event(message, ref) do
      {:ok, {:message, line}} -> IO.puts(line)
      {:ok, {:exit, exit}} -> IO.inspect(exit.code)
      :error -> :ignore
    end
end
```

Use `:line` mode for newline-framed stdout and `:raw` mode when later provider
migrations need exact byte chunks.

## IO Operations

`send/2` normalizes payloads and writes through the internal subprocess runtime
under a task-wrapped `GenServer.call`.

- line mode appends a trailing newline when needed
- raw mode preserves the exact bytes you send

```elixir
:ok = CliSubprocessCore.Transport.send(transport, %{kind: "ping"})
:ok = CliSubprocessCore.Transport.end_input(transport)
```

`end_input/1` uses the active stdin contract. Pipe-backed transports send
`:eof`; PTY-backed transports send the terminal EOF byte (`Ctrl-D`). Use it for
EOF-driven CLIs such as non-streaming `cat`, `python`, or provider commands
that wait for stdin closure before producing a final result.

`interrupt/1` uses the configured interrupt contract:

- `:signal` sends `SIGINT` to the subprocess process group
- `{:stdin, payload}` writes an exact interrupt payload such as `<<3>>`

Process-group signaling is owned explicitly by the core at interrupt and
shutdown time. The transport does not rely on the runtime's `:kill_group`
startup flag, because that flag can destabilize the shared `:exec` worker on
child exit.

## Metadata

`info/1` returns `%CliSubprocessCore.Transport.Info{}` with the normalized
invocation, generic execution-surface metadata, raw subprocess pid/os pid,
current status, stderr tail, delivery metadata, and the active `stdout_mode`,
`stdin_mode`, `pty?`, and `interrupt_mode` contract.

The generic metadata fields are:

- `surface_kind`
- `target_id`
- `lease_ref`
- `surface_ref`
- `boundary_class`
- `observability`
- `adapter_metadata`

`info.delivery.tagged_event_tag` exposes the actual tagged mailbox atom for
direct adapter seams. Outside the core, do not inspect the global `:exec`
worker or transport process state directly; `info/1` and `extract_event/2` are
the supported public contract.

## One-Shot Command Execution

`run/2` owns exact non-PTY command execution below the provider-aware command
lane:

```elixir
invocation =
  CliSubprocessCore.Command.new("sh", ["-c", "printf \"alpha\" && printf \"beta\" >&2"])

{:ok, result} =
  CliSubprocessCore.Transport.run(invocation,
    stderr: :stdout,
    timeout: 5_000
  )
```

Supported run options are:

- `:stdin` – exact stdin payload written before optional EOF
- `:timeout` – execution timeout in milliseconds or `:infinity`
- `:stderr` – `:separate` or `:stdout`
- `:close_stdin` – whether to send EOF after writing stdin, default `true`

The return value is `%CliSubprocessCore.Transport.RunResult{}` with captured
`stdout`, `stderr`, `output`, and normalized `exit` data.

## Stderr

stderr is handled in two ways at once:

- raw stderr chunks are dispatched to subscribers immediately
- the transport keeps a tail ring buffer retrievable via `stderr/1`
- when `:replay_stderr_on_subscribe?` is enabled, late subscribers receive the
  currently retained stderr tail immediately after they subscribe
- when `:buffer_events_until_subscribe?` is enabled, stdout/stderr/error events
  emitted before the first subscriber attaches are replayed in order

Optional `:stderr_callback` receives complete stderr lines. Partial trailing
stderr fragments are flushed through the callback during process finalization.

## Startup Modes

- `:eager` starts the subprocess during `init/1`. Startup failures return from
  `start/1` or `start_link/1` immediately.
- `:lazy` still performs deterministic startup preflight during
  `start/1` or `start_link/1` and only defers the actual subprocess launch to
  `handle_continue/2`.

`CliSubprocessCore.RawSession` and `CliSubprocessCore.Session` still wait for
startup to either connect or fail before they return. Use the transport
directly only when you intentionally want lazy-start semantics at the API
boundary.

## Buffering

Line-mode stdout is newline-framed and drained through an internal queue.
Oversized partial lines emit structured `Transport.Error.buffer_overflow/3`
events and recover at the next newline boundary, so one bad chunk does not
poison the rest of the stream.

Raw-mode stdout skips line framing and delivers exact output chunks directly to
subscribers.

## Raw Sessions

`CliSubprocessCore.RawSession` builds on the transport for long-lived
subprocess-backed families that still need provider-owned semantics above the
core.

Use it when you need:

- exact-byte stdin/stdout defaults
- optional PTY startup
- a stable raw-session handle instead of a bare transport pid
- normalized output collection through `%CliSubprocessCore.Transport.RunResult{}`

```elixir
{:ok, session} =
  CliSubprocessCore.RawSession.start("sh", ["-c", "cat"],
    stdin?: true,
    pty?: false
  )

:ok = CliSubprocessCore.RawSession.send_input(session, "alpha")
:ok = CliSubprocessCore.RawSession.close_input(session)

{:ok, result} = CliSubprocessCore.RawSession.collect(session, 5_000)
```

`RawSession.collect/2` requires the configured receiver to be the calling
process so the core can drain its own transport events deterministically.
`RawSession.start/2`, `start/3`, and `start_link/2` do not report success until
the underlying transport has either connected or returned a startup failure,
even if the transport itself is configured with `startup_mode: :lazy`.
`RawSession.info/1` also returns `delivery` metadata with the effective
receiver, tagged event atom, and transport ref for direct adapter code.

## Structured Errors

Transport APIs return:

```elixir
{:error, {:transport, %CliSubprocessCore.Transport.Error{}}}
```

The error struct carries:

- `:reason` – normalized machine-readable reason
- `:message` – human-readable message
- `:context` – extra debugging metadata such as cwd, preview, or size limits

See `guides/shutdown-and-timeouts.md` for close, force-close, interrupt, and
timeout behavior.
