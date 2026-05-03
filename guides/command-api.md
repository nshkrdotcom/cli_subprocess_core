# Command API

`CliSubprocessCore.Command` is the provider-aware one-shot command lane.

It combines:

- provider profile resolution
- normalized command construction
- generic `execution_surface` placement
- wrapped lower-lane failures with provider context

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

The return value is `CliSubprocessCore.Command.RunResult`.

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

When that surface resolves to `:local_subprocess`, the covered minimal lane
emits `ProcessExecutionIntent.v1` and runs through `ExecutionPlane.Process.run/2`.
Other surfaces resolve through `ExecutionPlane.Process.Transport.run/2` using
the same `execution_surface` contract.

## Governed Launch

Use `:governed_authority` only after a higher authority materializer has
selected the launch inputs for one effect. The authority must provide
authority, lease, and target refs plus a materialized command. Optional cwd,
env, config root, auth root, and base URL also belong in that authority value.

```elixir
{:ok, result} =
  CliSubprocessCore.Command.run(
    provider: :codex,
    prompt: "Review this diff",
    governed_authority: [
      authority_ref: "authority://cli/run",
      credential_lease_ref: "lease://codex/run",
      target_ref: "target://local/run",
      command: "/materialized/bin/codex",
      cwd: "/workspace",
      env: %{"CODEX_HOME" => "/materialized/codex-home"},
      clear_env?: true,
      config_root: "/materialized/config",
      auth_root: "/materialized/auth",
      base_url: "https://authority.example/v1"
    ]
  )
```

Governed launch fails closed when the caller also supplies command, cwd, env,
config-root, auth-root, base-URL, or model env override fields outside the
authority value. Standalone calls remain unchanged when
`:governed_authority` is absent.

## Result Shape

The returned core-owned result contains:

- `stdout`
- `stderr`
- `output`
- `stderr_mode`
- `exit`

`exit` is the core-owned `ProcessExit` facade.

## Error Shape

Command-lane failures are wrapped as `CliSubprocessCore.Command.Error`.

That wrapper preserves core-facing context such as the invocation or provider
while carrying the underlying lower-lane failure from `execution_plane`.
Transport failures surface through the core-owned `TransportError` facade.
