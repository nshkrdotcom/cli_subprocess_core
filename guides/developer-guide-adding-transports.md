# Developer Guide: Adding Transports

`cli_subprocess_core` owns the built-in transport families for the common CLI
lane. Higher layers author placement through `execution_surface`; they do not
name adapter modules directly.

This guide describes when you should add a new built-in transport family, what
files must change, and what should remain untouched in downstream repos.

## First Decision

Before adding a new transport, decide whether you need:

- a new built-in `surface_kind`
- a new backend behind the existing `:guest_bridge` family

Use a new built-in `surface_kind` when the attach or process-lifecycle model is
meaningfully different from the existing families. Examples:

- `:docker_exec`
- `:kubectl_exec`

Use `:guest_bridge` when the new environment can expose the existing bridge
contract and only needs a new bridge implementation or deployment fabric. That
path does not require a new public transport family.

If the new idea is really a control-plane concern rather than a transport
family, stop before touching the registry.

Examples that stay above the core:

- lease allocation
- pre-warmed pools
- scheduler-driven target reuse
- workspace fabric or sandbox provisioning

Those concerns should reuse `target_id`, `lease_ref`, `surface_ref`, and
`boundary_class` above the transport layer instead of minting a fake
`surface_kind`.

## Public Contract Boundary

The only public placement contract is `CliSubprocessCore.ExecutionSurface`.

It carries:

- `surface_kind`
- `transport_options`
- `target_id`
- `lease_ref`
- `surface_ref`
- `boundary_class`
- `observability`

It does not carry:

- command or args
- cwd/env/user launch inputs
- workspace policy
- approval policy
- adapter module names

Higher layers such as ASM and `jido_integration` stay transport-neutral by
passing this generic contract through unchanged.

## Ownership Model

Built-in transport registration is intentionally closed over the core. The
registry is internal in
`lib/cli_subprocess_core/execution_surface/registry.ex`.

That means:

- downstream applications can choose among built-in surfaces
- downstream applications cannot register a brand new `surface_kind`
- adding a new built-in transport family always requires a core change

This is deliberate. The common CLI lane needs one authoritative owner for
transport-family semantics, capability gating, and error normalization.

## `remote?` Versus `path_semantics`

These fields are related, but they are not interchangeable.

- `remote?` answers whether the transport crosses a remote control boundary
- `path_semantics` answers where command lookup, cwd handling, and PATH
  expectations live

Current built-in families happen to line up cleanly:

- `:local_subprocess` -> `remote?: false`, `path_semantics: :local`
- `:ssh_exec` -> `remote?: true`, `path_semantics: :remote`
- `:guest_bridge` -> `remote?: true`, `path_semantics: :guest`

Future families do not have to.

A local container/daemon-driven surface may legitimately be:

- `remote?: false`
- `path_semantics: :guest`

That is why command resolution and cwd-default logic must key off
`path_semantics`, not `remote?`. In the public helper layer, use:

- `ExecutionSurface.capabilities/1`
- `ExecutionSurface.path_semantics/1`
- `ExecutionSurface.nonlocal_path_surface?/1`

Use `remote?` only when you truly mean transport topology.

## Implementation Checklist

Adding a new built-in family usually means touching these areas.

### 1. Add the adapter module

Create a module under `lib/cli_subprocess_core/transport/` that implements:

- `CliSubprocessCore.ExecutionSurface.Adapter`
- `CliSubprocessCore.Transport`

`LocalSubprocess`, `SSHExec`, and `GuestBridge` are the reference patterns:

- `local_subprocess` is a thin adapter over the existing subprocess owner
- `ssh_exec` is a translating spawn-wrapper over the subprocess owner
- `guest_bridge` is a stateful attached transport with its own protocol

Choose the pattern that matches the new transport family instead of forcing
everything into one shape.

### 2. Define capabilities

Return a concrete `CliSubprocessCore.ExecutionSurface.Capabilities` struct from
`capabilities/0`.

The public facade uses these flags to reject unsupported generic operations
before dispatch. If the capability shape is wrong, callers will get the wrong
contract behavior even if the adapter itself works.

Be explicit about:

- `remote?`
- `startup_kind`
- `path_semantics`
- `supports_run?`
- `supports_streaming_stdio?`
- `supports_pty?`
- `supports_user?`
- `supports_env?`
- `supports_cwd?`
- `interrupt_kind`

Do not rely on defaults for restrictive families.

If the new family cannot support something, declare it explicitly in
`Capabilities`. Facade-level validation only enforces what the adapter reports.

Examples:

- a family without `run/2` must set `supports_run?: false`
- a family without PTY support must set `supports_pty?: false`
- a family without cwd/env/user support must set those fields to `false`
- a family without interrupt support must set `interrupt_kind` accordingly

This is part of the transport contract, not an optional implementation detail.

### 3. Normalize only transport-owned options

Implement `normalize_transport_options/1` for the adapter-specific attach or
connection inputs only.

Do not re-accept generic launch fields here:

- `command`
- `args`
- `cwd`
- `env`
- `clear_env?`
- `user`

Those stay in the shared transport option flow and are validated by the public
facade plus `Transport.Options`.

### 4. Register the new surface kind

Add the new adapter to
`lib/cli_subprocess_core/execution_surface/registry.ex`.

Also widen any closed `surface_kind` unions so the new family is reflected in:

- `CliSubprocessCore.ExecutionSurface`
- `CliSubprocessCore.Transport`
- any transport-facing typed structs or specs that enumerate the built-in kinds

### 5. Preserve generic dispatch

`CliSubprocessCore.Transport` must remain the public dispatch point. Do not
introduce public callers that select the adapter module directly.

The flow should stay:

1. caller authors `execution_surface`
2. `ExecutionSurface.resolve/1` validates and resolves the adapter
3. `Transport` enforces generic capability rules
4. the adapter executes the family-specific startup or run logic

### 6. Populate transport info correctly

Every long-lived transport owner must keep `Transport.Info` accurate.

At minimum, ensure the info snapshot preserves:

- surface metadata
- `adapter_capabilities`
- `effective_capabilities`
- any negotiated profile or protocol fields if the family negotiates
- family-specific adapter metadata that is useful for debugging

If the new family has attach negotiation, `effective_capabilities` may differ
from `adapter_capabilities`. If it does not negotiate, they should be the same.

### 7. Reuse the normalized error model

Do not invent a new public error family for generic capability failures.

Use the existing normalized transport errors, especially:

- `{:unsupported_capability, capability, surface_kind}`
- `{:invalid_options, reason}`
- `{:startup_failed, reason}`

If the family has a protocol boundary like `:guest_bridge`, normalize its
protocol and remote failures into structured transport errors rather than
leaking raw wire-level failures upward.

## What Usually Does Not Change Above The Core

If you add a new built-in transport family correctly, most downstream runtime
code should not need structural changes.

Normally unchanged:

- `agent_session_manager`
- `jido_integration`
- `jido_harness`
- provider SDK runtime code

Those layers already consume generic `execution_surface` and
`execution_environment` carriage.

What may still need updates:

- docs that enumerate supported surfaces
- examples or scripts that expose user-facing surface flags
- targeted tests that assert the allowed built-in `surface_kind` set

## Testing Requirements

A new built-in transport family is not complete without tests in four layers.

### Execution-surface tests

Add or update tests for:

- accepted `surface_kind`
- transport-option normalization
- registry lookup
- invalid option rejection

### Capability-gating tests

Add facade-level tests that prove unsupported generic operations are rejected
before dispatch where appropriate.

Examples:

- PTY on a non-PTY family
- `run/2` on a non-run family
- `cwd` on a family that does not support working directories

Also add at least one conformance test that proves `path_semantics` can differ
from `remote?`, so future local-but-guest families do not regress the command
resolution layer.

### Adapter behavior tests

Add family-specific tests for:

- startup
- one-shot run
- stdin/stdout/stderr delivery
- interrupt semantics
- close and force-close behavior
- `Transport.Info` metadata

### Conformance and live tests

If the family depends on external tools or infrastructure, provide both:

- fake or contract tests for deterministic behavior
- opt-in live tests for real integration proof

## Choosing The Right Abstraction

Use the smallest abstraction that matches the new family.

If the family can be represented as “translate to a command and spawn it,”
follow the `SSHExec` pattern.

If the family needs a long-lived attach protocol with negotiation and runtime
RPC, follow the `GuestBridge` pattern.

If it is still just a local child process with no extra transport options,
follow the `LocalSubprocess` pattern.

Do not build a full bridge protocol for a transport that only needs command
translation, and do not force a complex attach family into a spawn-wrapper just
because subprocess support already exists.

## Transport Auth For Future Credentialed Families

Some future transport families may need transport-layer credentials even when
the provider CLI does not.

Examples:

- `:aws_ssm`
- future daemon-backed control channels

The public transport contract must stay secret-free.

Use:

- `transport_options[:credential_binding_ref]`

You may also carry non-secret selectors such as:

- `:region`
- `:profile`
- `:role_arn`
- target identifiers such as instance, pod, or daemon selectors

Do not put any of the following into `ExecutionSurface` or public
`transport_options`:

- raw secret values
- callback closures
- Jido auth structs or lease structs

Credentialed adapters should resolve secrets through a configured resolver
owned outside the public core contract. If the binding ref is required, reject
missing, `nil`, or empty `credential_binding_ref` inputs loudly during adapter
normalization or startup. If metadata needs to expose auth lineage, expose only
redacted binding identifiers or digests.

## Downstream Authoring Example

Once a built-in family exists, higher layers should only need to author the
generic placement contract:

```elixir
execution_surface: [
  surface_kind: :ssh_exec,
  transport_options: [
    destination: "buildbox-1",
    ssh_user: "deploy"
  ],
  target_id: "target-1",
  lease_ref: "lease-1",
  surface_ref: "surface-1",
  boundary_class: :isolated
]
```

That is the desired ergonomics. Downstream callers choose a surface family and
pass transport-owned metadata. They do not wire adapter modules, capability
tables, or registry entries themselves.
