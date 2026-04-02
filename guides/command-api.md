# Command API

`CliSubprocessCore.Command` is the provider-aware one-shot command lane.

It combines:

- provider profile resolution
- normalized command construction
- generic `execution_surface` placement
- wrapped transport failures with provider context

## Public Entry Points

- `CliSubprocessCore.Command.run/1`
- `CliSubprocessCore.Command.run/2`
- `CliSubprocessCore.Command.new/3`

## Provider-Aware Execution

```elixir
{:ok, result} =
  CliSubprocessCore.Command.run(
    provider: :claude,
    prompt: "Summarize this repository"
  )
```

The return value is `ExternalRuntimeTransport.Transport.RunResult`.

## Prebuilt Invocation Execution

```elixir
invocation =
  CliSubprocessCore.Command.new(
    "sh",
    ["-c", "printf alpha"]
  )

{:ok, result} = CliSubprocessCore.Command.run(invocation, timeout: 5_000)
```

## Placement

Use `execution_surface` to move the command onto a different substrate without
exposing adapter modules:

```elixir
{:ok, result} =
  CliSubprocessCore.Command.run(
    provider: :codex,
    prompt: "Review this diff",
    execution_surface: [
      surface_kind: :ssh_exec,
      transport_options: [
        destination: "buildbox.example",
        ssh_user: "deploy"
      ]
    ]
  )
```

## Result Shape

The returned transport-owned result contains:

- `stdout`
- `stderr`
- `output`
- `stderr_mode`
- `exit`

`exit` is an `ExternalRuntimeTransport.ProcessExit`.

## Error Shape

Command-lane failures are wrapped as `CliSubprocessCore.Command.Error`.

That wrapper preserves core-facing context such as the invocation or provider
while carrying the underlying transport failure from
`ExternalRuntimeTransport.Transport.Error`.
