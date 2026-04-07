# Getting Started

`cli_subprocess_core` is the provider-facing runtime layer above
`external_runtime_transport`.

Use it when you want normalized provider commands, sessions, payloads, and
events instead of working directly with the raw transport substrate.

## Install

```elixir
def deps do
  [
    {:cli_subprocess_core, "~> 0.1.0"}
  ]
end
```

## Choose The Right API

Use:

- `CliSubprocessCore.Command` for provider-aware one-shot execution
- `CliSubprocessCore.RawSession` for long-lived raw subprocess ownership
- `CliSubprocessCore.Session` for normalized provider events
- `CliSubprocessCore.Channel` or `CliSubprocessCore.ProtocolSession` for framed
  or protocol-driven sessions

## One-Shot Commands

```elixir
{:ok, result} =
  CliSubprocessCore.Command.run(
    provider: :claude,
    prompt: "Summarize the latest changes"
  )
```

The result type is
`ExternalRuntimeTransport.Transport.RunResult`. The core keeps provider-facing
planning and error wrapping around that transport-owned result.

## Raw Sessions

```elixir
{:ok, session} =
  CliSubprocessCore.RawSession.start("sh", ["-c", "cat"], stdin?: true)

:ok = CliSubprocessCore.RawSession.send_input(session, "alpha")
:ok = CliSubprocessCore.RawSession.close_input(session)

{:ok, result} = CliSubprocessCore.RawSession.collect(session, 5_000)
```

`RawSession` is the lowest public CLI-owned layer. It uses
`ExternalRuntimeTransport.Transport` underneath but keeps the public placement
seam generic.

## Normalized Sessions

```elixir
ref = make_ref()

{:ok, session, info} =
  CliSubprocessCore.Session.start_session(
    provider: :codex,
    prompt: "Review this change",
    subscriber: {self(), ref}
  )

IO.inspect(info.transport.info.surface_kind)
```

## Execution Surface

Placement stays on one `execution_surface` contract:

```elixir
execution_surface = [
  surface_kind: :ssh_exec,
  transport_options: [
    destination: "buildbox.example",
    ssh_user: "deploy"
  ],
  target_id: "buildbox-1",
  boundary_class: :remote
]
```

Pass that value through `Command.run/1`, `Command.run/2`,
`RawSession.start/2`, or `Session.start_session/1`.

Supported landed surface kinds are:

- `:local_subprocess`
- `:ssh_exec`
- `:guest_bridge`
