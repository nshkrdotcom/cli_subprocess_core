# Developer Guide: Provider Profiles and Command Construction

This guide explains how provider profiles fit into the core runtime.

The focus here is not on any one SDK. The focus is the internal boundary inside
`cli_subprocess_core` between policy, command construction, and subprocess
execution.

## What a Provider Profile Is

A provider profile is the core’s adapter for one external CLI family.

It answers questions like:

- which executable should be launched
- which flags should be emitted
- how input should be shaped for that CLI
- how provider-specific output is normalized back into the shared runtime

The contract is defined by:

- `lib/cli_subprocess_core/provider_profile.ex`

Built-in implementations live in:

- `lib/cli_subprocess_core/provider_profiles/codex.ex`
- `lib/cli_subprocess_core/provider_profiles/claude.ex`
- `lib/cli_subprocess_core/provider_profiles/gemini.ex`
- `lib/cli_subprocess_core/provider_profiles/amp.ex`

## The Three Internal Stages

Inside the core, it is helpful to think in three stages:

1. policy
2. command construction
3. transport/session execution

Stage 1 is the model registry and related validation.

Stage 2 is the provider profile turning normalized options into command-line
arguments and runtime expectations.

Stage 3 is the subprocess transport and session runtime actually starting and
managing the external process.

These stages should stay distinct.

Governed launch adds one more boundary rule: if `:governed_authority` is
present, provider profiles must not accept command, cwd, env, config-root,
auth-root, base-URL, or model env override values from ordinary caller options.
Those values must already be materialized by the authority and must run with
`clear_env?: true`. The standalone path keeps the normal provider CLI env and
local discovery behavior when no governed authority is supplied.

## What Profiles Should Do

Profiles should:

- accept normalized input
- consume the resolved model selection
- emit the correct executable and flags
- define provider-specific environment and framing behavior
- normalize provider output into the shared event model

## What Profiles Should Not Do

Profiles should not:

- own model catalogs
- choose fallback models
- silently accept placeholder model input
- invent a second reasoning-effort policy
- override core selection decisions

If a change belongs to policy, it should go into the model registry instead.

## Command Construction Flow

At a high level, command construction looks like this:

1. caller supplies normalized options
2. model registry resolves the final selection
3. provider profile reads the resolved selection
4. provider profile builds executable, argv, env, and transport expectations
5. command/session layers run the process

The important internal rule is simple:

- the profile writes the command
- the registry decides the model

## Example Boundary

For a Codex request, the core should conceptually follow this pattern:

```elixir
{:ok, selection} =
  CliSubprocessCore.ModelRegistry.build_arg_payload(
    :codex,
    requested_model,
    reasoning_effort: requested_effort
  )

# The provider profile then formats "--model #{selection.resolved_model}"
```

The provider profile may still sanitize transport-level placeholders before
emitting flags, but it must not implement fallback policy there.

## Reviewer Checklist

When reviewing a provider-profile change, ask:

- is this truly profile behavior, or is it model policy?
- does the profile read the core selection instead of re-resolving a model?
- are emitted flags consistent with the resolved selection?
- does the profile preserve the shared runtime/event contract?

If the answer depends on provider-wide model rules, the change probably belongs
in the registry or catalog, not the profile.
