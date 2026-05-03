<p align="center">
  <img src="assets/cli_subprocess_core.svg" alt="CliSubprocessCore logo" width="240" />
</p>

# CliSubprocessCore

<p align="center">
  <a href="https://hex.pm/packages/cli_subprocess_core">
    <img src="https://img.shields.io/hexpm/v/cli_subprocess_core.svg" alt="Hex" />
  </a>
  <a href="https://hexdocs.pm/cli_subprocess_core">
    <img src="https://img.shields.io/badge/hexdocs-docs-blue.svg" alt="HexDocs" />
  </a>
  <a href="https://github.com/nshkrdotcom/cli_subprocess_core">
    <img src="https://img.shields.io/badge/github-nshkrdotcom%2Fcli__subprocess__core-24292e.svg" alt="GitHub" />
  </a>
</p>

`cli_subprocess_core` is the shared runtime for provider-facing CLIs. It owns
provider profile resolution, normalized command/session APIs, event and payload
shaping, model policy helpers, and the built-in first-party profiles for
Claude, Codex, Gemini, and Amp.

The covered one-shot local process lane and the local session-bearing process
lane now run on `execution_plane`. `cli_subprocess_core` keeps one public
placement seam, `execution_surface`, while the shared lower substrate for
local and non-local runtime execution now lives in `execution_plane`.

Downstream provider SDKs get this default local CLI execution path by depending
on `cli_subprocess_core`; they do not need to declare Execution Plane packages
manually for ordinary subprocess use.

For downstream packages that still type against the historical module name,
`CliSubprocessCore.ExecutionSurface` remains available as a compatibility
facade over `ExecutionPlane.Process.Transport.Surface`.

## What This Package Owns

- `CliSubprocessCore.Command` for provider-aware one-shot CLI execution.
- `CliSubprocessCore.RawSession` for provider-agnostic long-lived raw sessions.
- `CliSubprocessCore.Session` for normalized provider sessions and event fanout.
- `CliSubprocessCore.Channel`, `CliSubprocessCore.ProtocolSession`, and
  `CliSubprocessCore.JSONRPC` for framed or protocol-driven CLI interactions.
- `CliSubprocessCore.ProviderProfile`, `CliSubprocessCore.ProviderRegistry`,
  and `CliSubprocessCore.ProviderProfiles.*` for provider-specific command
  planning and parsing.
- `CliSubprocessCore.Event`, `CliSubprocessCore.Payload.*`, and
  `CliSubprocessCore.Runtime` for the shared runtime vocabulary.
- `CliSubprocessCore.Tool.*` for serializable tool descriptors, requests, and
  responses that contain no executable host callbacks.
- `CliSubprocessCore.ModelRegistry`, `CliSubprocessCore.ModelInput`, and
  related catalog helpers for centralized model policy.

## What This Package Does Not Own

`cli_subprocess_core` no longer owns the lower process substrate.

For the covered runtime slice:

- `execution_plane` owns execution-surface validation, capability lookup,
  lower transport dispatch, and the local/non-local raw process substrate
- `cli_subprocess_core` owns provider planning, normalized command/session
  APIs, and event projection above that lower owner

## Installation

```elixir
def deps do
  [
    {:cli_subprocess_core, "~> 0.1.0"}
  ]
end
```

## Quick Start

Run a provider-aware one-shot command:

```elixir
{:ok, result} =
  CliSubprocessCore.Command.run(
    provider: :claude,
    prompt: "Summarize this repository"
  )

IO.inspect(result.output)
```

Move that command onto SSH through the generic placement seam:

```elixir
{:ok, result} =
  CliSubprocessCore.Command.run(
    provider: :codex,
    prompt: "Review the latest diff",
    execution_surface: [
      surface_kind: :ssh_exec,
      transport_options: [
        destination: "buildbox.example",
        ssh_user: "deploy"
      ]
    ]
  )
```

Use `RawSession` when you need exact-byte ownership and normalized collection:

```elixir
{:ok, session} =
  CliSubprocessCore.RawSession.start("sh", ["-c", "cat"], stdin?: true)

:ok = CliSubprocessCore.RawSession.send_input(session, "alpha")
:ok = CliSubprocessCore.RawSession.close_input(session)

{:ok, result} = CliSubprocessCore.RawSession.collect(session, 5_000)
IO.inspect({result.stdout, result.exit.code})
```

Use `Session` when you want normalized provider events:

```elixir
ref = make_ref()

{:ok, _session, info} =
  CliSubprocessCore.Session.start_session(
    provider: :gemini,
    prompt: "Hello from the shared runtime",
    subscriber: {self(), ref}
  )

IO.inspect(info.delivery)
```

## Execution Surface

`cli_subprocess_core` keeps the public placement seam intentionally narrow. The
only public way to choose where a command runs is one `execution_surface`
value.

That contract carries:

- `contract_version`
- `surface_kind`
- `transport_options`
- `target_id`
- `lease_ref`
- `surface_ref`
- `boundary_class`
- `observability`

It does not expose adapter module names. Public callers do not choose
`LocalSubprocess`, `SSHExec`, or `GuestBridge` directly.

Callers may supply that value either as:

- `execution_surface: [...]`
- `execution_surface: %{...}`
- `execution_surface: %CliSubprocessCore.ExecutionSurface{}`

The first two are the preferred long-term shapes. The struct form remains for
downstream compatibility.

When that surface needs to cross a boundary, use
`CliSubprocessCore.ExecutionSurface.to_map/1` to project the versioned map
form.

For `CliSubprocessCore.Command.run/1,2`, `surface_kind: :local_subprocess`
now emits `ProcessExecutionIntent.v1` and delegates the covered minimal one-shot
lane to `ExecutionPlane.Process.run/2` with direct lower-lane-owner
provenance. That provenance is an honest standalone lane-owner claim; it is not
node-admitted Citadel governance. Non-local command placement and the
session-bearing APIs resolve through `ExecutionPlane.Process.Transport`.

## Governed Launch Authority

Standalone provider calls still honor the normal provider CLI path env, local
`PATH`, known home locations, and provider-local config behavior. Governed
calls are separate. Pass `:governed_authority` to `CliSubprocessCore.Command`
when a higher authority materializer has already selected the command, cwd,
env, target, config root, auth root, base URL, and cleanup posture for one
effect.

Governed launch requires `clear_env?: true` and rejects unmanaged caller
smuggling through `:command`, `:executable`, `:command_spec`, provider CLI path
keys, `:cwd`, `:env`, config roots, auth roots, base URLs, and model payload
env overrides. Provider CLI resolution also bypasses ambient provider CLI env,
`PATH`, npx, known home locations, and version-manager env while governed.

Materialized authority values are carried as refs and redacted shape evidence;
raw env values remain in the bounded child process launch only.

## Documentation

- `guides/getting-started.md` for the main public entrypoints.
- `guides/execution-surface-compatibility.md` for the compatibility facade
  exported for downstream packages.
- `guides/recovery-envelope.md` for the shared failure-normalization contract
  consumed by higher runtimes.
- `guides/command-api.md`, `guides/channel-api.md`, and `guides/session-api.md`
  for the primary runtime APIs.
- `guides/raw-transport.md` and `guides/shutdown-and-timeouts.md` for the
  transport boundary surfaced through `RawSession`.
- `guides/developer-guide-adding-transports.md` for the ownership rule after
  extraction.
- `examples/README.md` for runnable examples.
## Emergency Hardening Surfaces

`cli_subprocess_core` now preserves the transport hardening controls that matter to upper layers
instead of flattening them away inside provider defaults.

- shared provider-profile transport options retain `max_buffer_size`,
  `oversize_line_chunk_bytes`, `max_recoverable_line_bytes`, `oversize_line_mode`, and
  `buffer_overflow_mode`
- the common capability vocabulary now has a stable place for session-history, resume, pause, and
  intervention support
- tool capability metadata separates normalized `tool_use`/`tool_result` observation from
  host-executable tools and provider-native tool controls
- higher layers can reason about fatal data-loss boundaries without re-inventing transport-specific
  heuristics

This repo is still not a retry engine. It is the boundary that keeps subprocess and provider
profiles honest about what can be recovered and what must fail.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
