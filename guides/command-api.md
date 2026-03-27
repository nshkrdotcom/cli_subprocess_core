# Command API

`CliSubprocessCore.Command` owns the provider-aware one-shot command boundary
for shared non-PTY CLI flows.

Use this lane when you need:

- provider/profile command construction without starting a long-lived session
- exact stdin writes without the session transport's newline framing
- captured stdout, stderr, timeout, and normalized exit data
- a core-owned replacement for repeated SDK-local `:exec.run` helpers

## Direct Invocation

Use `run/2` when you already have a normalized invocation:

```elixir
invocation =
  CliSubprocessCore.Command.new("sh", ["-c", "printf \"alpha\" && printf \"beta\" >&2"])

{:ok, result} =
  CliSubprocessCore.Command.run(invocation,
    stderr: :stdout,
    timeout: 5_000
  )

result.stdout
# => "alpha"

result.stderr
# => "beta"

result.output
# => "alphabeta"
```

The return value is `%CliSubprocessCore.Transport.RunResult{}` with:

- `:invocation`
- `:stdout`
- `:stderr`
- `:output`
- `:exit`
- `:stderr_mode`

Non-zero exits still return `{:ok, result}`. The normalized
`result.exit.status` and `result.exit.code` are what provider wrappers should
map into provider-native public errors.

Invalid command-lane options, provider lookup failures, profile command-plan
failures, and wrapped transport failures return
`{:error, %CliSubprocessCore.Command.Error{}}`. Provider wrappers should map
that structured error instead of rebuilding a second common one-shot error
contract.

## Provider-Aware Execution

Use `run/1` when the core should resolve a provider profile and build the
invocation for you:

```elixir
{:ok, result} =
  CliSubprocessCore.Command.run(
    provider: :claude,
    prompt: "summarize the repo",
    timeout: 10_000
  )
```

Reserved command-lane options are:

- `:provider`
- `:profile`
- `:registry`
- `:stdin`
- `:timeout`
- `:stderr`
- `:close_stdin`
- `:surface_kind`
- `:transport_options`
- `:target_id`
- `:lease_ref`
- `:surface_ref`
- `:boundary_class`
- `:observability`

All remaining options are passed to `build_invocation/1` on the resolved
provider profile. The core resolves the concrete transport adapter internally
from `:surface_kind`, so callers should not choose transport modules directly.
The landed surfaces today are `:local_subprocess`, `:static_ssh`, and
`:leased_ssh`; `:guest_bridge` remains deferred and is still rejected. Legacy
backend-selection overrides are rejected.

## Transport Boundary

The provider-aware command lane delegates exact process execution to
`CliSubprocessCore.Transport.run/2`.

That lower layer owns:

- subprocess startup for one-shot non-PTY execution
- exact stdin writes
- stdout and stderr collection
- timeout cleanup
- normalized `%CliSubprocessCore.ProcessExit{}` output

Provider wrappers should stay thin:

- translate public options into provider profile inputs or a direct invocation
- call `CliSubprocessCore.Command.run/1` or `run/2`
- map `%CliSubprocessCore.Transport.RunResult{}` into provider-native public
  result structs
- map `%CliSubprocessCore.Command.Error{}` into provider-native public errors

They should not keep a second `:exec.run` loop for common CLI flows.
