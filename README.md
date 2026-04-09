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

The raw execution substrate now lives in `external_runtime_transport`.
`cli_subprocess_core` consumes that package through one public placement seam:
`execution_surface`.

For downstream packages that still type against the historical module name,
`CliSubprocessCore.ExecutionSurface` remains available as a compatibility
facade over `ExternalRuntimeTransport.ExecutionSurface`.

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
- `CliSubprocessCore.ModelRegistry`, `CliSubprocessCore.ModelInput`, and
  related catalog helpers for centralized model policy.

## What This Package Does Not Own

`cli_subprocess_core` no longer owns the raw execution substrate modules. The
following are owned by `external_runtime_transport`:

- `ExternalRuntimeTransport.ExecutionSurface`
- `ExternalRuntimeTransport.Transport`
- adapter registry and transport contracts
- built-in `:local_subprocess`, `:ssh_exec`, and `:guest_bridge` families
- shared `ProcessExit`, `LineFraming`, and transport result types

That separation keeps provider/runtime behavior in the core while leaving raw
process placement reusable by non-CLI stacks.

The compatibility facade does not change that ownership boundary. Transport
validation, capabilities, and dispatch still live in
`ExternalRuntimeTransport.ExecutionSurface`.

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
`CliSubprocessCore.ExecutionSurface.to_map/1` or
`ExternalRuntimeTransport.ExecutionSurface.to_map/1` to project the versioned
map form.

## Documentation

- `guides/getting-started.md` for the main public entrypoints.
- `guides/external-runtime-transport.md` for the shared placement seam.
- `guides/execution-surface-compatibility.md` for the compatibility facade
  exported for downstream packages.
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
- higher layers can reason about fatal data-loss boundaries without re-inventing transport-specific
  heuristics

This repo is still not a retry engine. It is the boundary that keeps subprocess and provider
profiles honest about what can be recovered and what must fail.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
