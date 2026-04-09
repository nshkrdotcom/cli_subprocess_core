# Raw Sessions And Transport

`cli_subprocess_core` no longer owns the raw subprocess substrate.
`ExecutionPlane.Process.Transport` owns the local session-bearing process lane,
and the same transport seam also owns non-local placement beneath the shared
`execution_surface` contract.

`CliSubprocessCore.RawSession` is the core-owned handle above that substrate
when you want exact-byte stdin/stdout defaults without provider parsing.

## Public Modules

- `CliSubprocessCore.RawSession` for a stable raw-session handle above the
  extracted transport layer
- `ExecutionPlane.Process.Transport` for direct transport lifecycle control
- `ExecutionPlane.Process.Transport.Options` for validated startup options
- `ExecutionPlane.Process.Transport.RunOptions` for validated one-shot
  execution options
- `ExecutionPlane.Process.Transport.RunResult` for captured direct transport
  execution results
- `ExecutionPlane.Process.Transport.Error` for direct transport failures
- compatibility-projected `ExternalRuntimeTransport.Transport.Info`,
  `ExternalRuntimeTransport.Transport.Error`, and
  `ExternalRuntimeTransport.ProcessExit` where `RawSession`, `Channel`, or
  `Session` preserve historical public shapes

## Start A Raw Session

Use `CliSubprocessCore.RawSession` when you want the core-owned raw-session
handle and normalized result collection:

```elixir
{:ok, session} =
  CliSubprocessCore.RawSession.start("sh", ["-c", "cat"],
    stdin?: true,
    stdout_mode: :raw,
    stdin_mode: :raw
  )

:ok = CliSubprocessCore.RawSession.send_input(session, "alpha")
:ok = CliSubprocessCore.RawSession.close_input(session)

{:ok, result} = CliSubprocessCore.RawSession.collect(session, 5_000)
IO.inspect({result.stdout, result.exit.code})
```

`RawSession.start/2,3` and `start_link/2,3` still accept the shared generic
placement contract through one `:execution_surface` value.

## Shared Execution Surface

Placement stays generic above the substrate:

- `:surface_kind`
- `:transport_options`
- `:target_id`
- `:lease_ref`
- `:surface_ref`
- `:boundary_class`
- `:observability`

Landed built-in surface kinds are:

- `:local_subprocess`
- `:ssh_exec`
- `:guest_bridge`

Use `CliSubprocessCore.ExecutionSurface.capabilities/1`,
`path_semantics/1`, `remote_surface?/1`, and `nonlocal_path_surface?/1` when a
higher layer needs to reason about placement without reaching around the seam.

## Direct Transport Access

Use `ExecutionPlane.Process.Transport` directly when you need transport-level
lifecycle control or exact non-provider one-shot execution.

```elixir
alias ExecutionPlane.Command
alias ExecutionPlane.Process.Transport

command =
  Command.new("sh", ["-c", "cat"],
    env: %{"TERM" => "xterm-256color"}
  )

ref = make_ref()

{:ok, transport} =
  Transport.start(
    command: command,
    subscriber: {self(), ref},
    startup_mode: :eager
  )
```

Supported startup options are normalized by the shared lower transport options
contract:

- `:command` or a normalized `ExecutionPlane.Command`
- `:args`, default `[]`
- `:cwd`, default `nil`
- `:env`, default `%{}`
- `:clear_env?`, default `false`
- `:user`, default `nil`
- `:stdout_mode`, `:line` or `:raw`, default `:line`
- `:stdin_mode`, `:line` or `:raw`, default `:line`
- `:pty?`, default `false`
- `:interrupt_mode`, `:signal` or `{:stdin, payload}`
- `:subscriber`, `pid()` or `{pid(), :legacy | reference()}`
- `:startup_mode`, `:eager` or `:lazy`
- `:task_supervisor`, default `ExecutionPlane.TaskSupervisor`
- `:event_tag`, default `:execution_plane_process`
- `:headless_timeout_ms`, default `30_000`
- `:max_buffer_size`, default `1_048_576`
- `:max_stderr_buffer_size`, default `262_144`
- `:max_buffered_events`, default `128`
- `:stderr_callback`, default `nil`
- `:close_stdin_on_start?`, default `false`
- `:replay_stderr_on_subscribe?`, default `false`
- `:buffer_events_until_subscribe?`, default `false`

## Event Model

Direct transport subscribers receive the transport-owned mailbox contract.
Legacy subscribers receive:

- `{:transport_message, line}`
- `{:transport_data, chunk}`
- `{:transport_error, %ExecutionPlane.Process.Transport.Error{}}`
- `{:transport_stderr, chunk}`
- `{:transport_exit, %ExecutionPlane.ProcessExit{}}`

Tagged subscribers receive:

- `{event_tag, ref, {:message, line}}`
- `{event_tag, ref, {:data, chunk}}`
- `{event_tag, ref, {:error, %ExecutionPlane.Process.Transport.Error{}}}`
- `{event_tag, ref, {:stderr, chunk}}`
- `{event_tag, ref, {:exit, %ExecutionPlane.ProcessExit{}}}`

Use `ExecutionPlane.Process.Transport.extract_event/2` instead of
hard-coding the outer event atom:

```elixir
receive do
  message ->
    case ExecutionPlane.Process.Transport.extract_event(message, ref) do
      {:ok, {:message, line}} -> IO.puts(line)
      {:ok, {:exit, exit}} -> IO.inspect(exit.code)
      :error -> :ignore
    end
end
```

`CliSubprocessCore.RawSession` keeps the same underlying transport event
payloads while carrying them through a core-owned session handle.

## IO Operations

`ExecutionPlane.Process.Transport.send/2` normalizes payloads through the
active stdin mode:

- line mode appends a trailing newline when needed
- raw mode preserves exact bytes

```elixir
:ok = ExecutionPlane.Process.Transport.send(transport, %{kind: "ping"})
:ok = ExecutionPlane.Process.Transport.end_input(transport)
```

`end_input/1` sends EOF through the active stdin contract. `interrupt/1`
follows the transport-owned interrupt contract and surfaces the resulting exit
as an `ExecutionPlane.ProcessExit`.

## Metadata

`CliSubprocessCore.RawSession.info/1` includes a `transport` entry containing
`%ExternalRuntimeTransport.Transport.Info{}` projected from the shared
Execution Plane transport snapshot.

That transport snapshot carries:

- the normalized invocation
- generic execution-surface metadata
- retained stderr tail
- delivery metadata
- the active `stdout_mode`, `stdin_mode`, `pty?`, and `interrupt_mode`

The generic placement metadata remains:

- `surface_kind`
- `target_id`
- `lease_ref`
- `surface_ref`
- `boundary_class`
- `observability`
- `adapter_metadata`

## One-Shot Command Execution

For direct exact-byte execution below provider parsing, use
`ExecutionPlane.Process.Transport.run/2`:

```elixir
alias ExecutionPlane.Command
alias ExecutionPlane.Process.Transport

command =
  Command.new("sh", ["-c", "printf \"alpha\" && printf \"beta\" >&2"])

{:ok, result} =
  Transport.run(command,
    stderr: :stdout,
    timeout: 5_000
  )
```

Supported run options are:

- `:stdin`
- `:timeout`
- `:stderr`
- `:close_stdin`

The return value is `%ExecutionPlane.Process.Transport.RunResult{}` with
captured `stdout`, `stderr`, `output`, and normalized `exit` data.

## Buffering And Shutdown

Buffering, stderr retention, startup modes, interrupt delivery, and forced
shutdown are transport-owned behaviors now. `CliSubprocessCore.RawSession`,
`Channel`, and `Session` forward those semantics upward without re-owning the
substrate internals.

See `guides/shutdown-and-timeouts.md` for the surfaced lifecycle contract and
`guides/external-runtime-transport.md` for the package split.
## Chunk-First Overflow Controls

When a provider profile opts into line-based stdout framing, the raw transport now exposes the full
oversize-line control set:

- `:max_buffer_size`
- `:oversize_line_chunk_bytes`
- `:max_recoverable_line_bytes`
- `:oversize_line_mode`
- `:buffer_overflow_mode`

The intended default is `:chunk_then_fail` plus `:fatal`: try to reconstruct the complete line
within a bounded window, then raise a structured overflow error once the recoverable ceiling is
exceeded. Provider profiles should pass those values through transparently rather than silently
reverting to optimistic drop-and-continue behavior.
