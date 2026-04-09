# Developer Guide: Runtime Layers and Core Boundaries

This guide explains the internal layer boundaries in `cli_subprocess_core`.

It is intended for people reviewing the core architecture, extending the core,
or trying to understand where a change should land.

## The Core Layers

`cli_subprocess_core` has a small set of important layers:

1. model policy
2. provider profile adaptation
3. command/session normalization
4. execution-surface routing and lower runtime execution
5. normalized event and payload emission

These layers exist so the runtime can stay consistent while still supporting
multiple external CLI families.

## Schema Ownership Inside The Layers

The shared schema boundary sits beside the existing runtime layers, not above
them as a second architecture.

- `CliSubprocessCore.Schema` owns the shared `Zoi` validation contract for
  core-owned dynamic boundaries.
- `CliSubprocessCore.Event`, `CliSubprocessCore.Payload.*`,
  `CliSubprocessCore.ModelRegistry.Model`,
  `CliSubprocessCore.ModelRegistry.Selection`, and
  `CliSubprocessCore.ModelInput` use that schema layer at map ingress and then
  project back into the existing public structs.
- Forward-compatible shared wire surfaces use
  `Zoi.map(..., unrecognized_keys: :preserve)` plus projection so future fields
  survive in `extra` where the boundary needs them.
- Closed boundaries may still use direct struct validation, but evolving wire
  surfaces should not depend on `Zoi.struct/3`.
- Provider-native app-server, control-protocol, and orchestration schemas stay
  in the downstream repos that own those boundaries.

## Layer 1: Model Policy

Owned by:

- `CliSubprocessCore.ModelRegistry`
- the internal model catalog loader and catalog data under `priv/models`

This layer answers:

- which models exist
- which model should be used
- whether the request is valid
- which reasoning values are allowed

## Layer 2: Provider Profile Adaptation

Owned by:

- `CliSubprocessCore.ProviderProfile`
- built-in provider profile modules

This layer answers:

- how to translate normalized intent into provider-specific CLI behavior
- how to interpret provider-specific output inside the shared runtime

## Layer 3: Command and Session Normalization

Owned by modules such as:

- `CliSubprocessCore.Command`
- `CliSubprocessCore.Command.Options`
- `CliSubprocessCore.Session`
- `CliSubprocessCore.Session.Options`

This layer gives the core a provider-agnostic API for one-shot commands and
longer-lived sessions.

## Layer 4: Lower Runtime Execution

Owned by the lower owner for the selected lane:

- `ExecutionPlane.Process` for the covered local one-shot command lane
- `ExternalRuntimeTransport.Transport` for the remaining raw/session-bearing and non-local surfaces

This layer starts the external process, manages stdin/stdout/stderr, and
captures process exit information through the shared substrate.

It should remain blind to provider policy.

That includes provider-native approval and sandbox posture. The transport layer
owns how the process is attached or started. It does not own whether a
particular provider should run with a permissive mode such as "danger full
access."

If a remote CLI launched over `:ssh_exec` later fails inside its own sandbox
backend, that is already above the transport-placement boundary. A common real
example is a remote Linux host where the provider CLI tries to use `bwrap` and
the host's AppArmor or userns policy blocks the loopback/userns setup. The
core transport succeeded; the remote runtime or host policy did not.

## Layer 5: Event and Payload Emission

Owned by:

- `CliSubprocessCore.Event`
- `CliSubprocessCore.Payload.*`
- `CliSubprocessCore.Runtime`

This layer turns provider/runtime activity into the shared event model that the
rest of the stack consumes.

## The Practical Boundary Rule

When deciding where a change belongs, use this rule:

- if the change affects model choice, put it in the registry/catalog
- if the change affects provider CLI syntax, put it in the provider profile
- if the change affects the covered local one-shot subprocess lane, put it in the execution-plane-backed lower runtime
- if the change affects raw/session or non-local subprocess lifecycle, put it in transport/session
- if the change affects normalized output shape, put it in payload/runtime

That rule prevents policy leakage across layers.

## Example Integration Shape

External repos should consume the core in this order:

1. prepare normalized options
2. call the core’s model registry
3. pass the resolved selection into provider-facing command building
4. let the core route the request to the execution-plane-backed command lane or the raw/session transport runtime as appropriate

The core is therefore both:

- a policy owner
- and a command/session boundary above lower runtime owners

But those are still separate internal responsibilities.

## What Reviewers Should Watch For

Architecture drift usually shows up as one of these mistakes:

- a provider profile starts choosing fallback models
- transport code learns provider policy
- consumer-facing behavior bypasses normalized payloads
- multiple layers define overlapping defaults

If one layer can be removed without changing the others, the boundaries are
probably healthy. If a small change requires editing policy, profile, and
transport logic together, the responsibilities are probably leaking.
