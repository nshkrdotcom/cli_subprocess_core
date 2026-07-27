# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-07-27

### Added

- Total `:structured_output` and `:completion_only` feature manifests for all
  built-in providers plus `ProviderFeatures.Error`, whose provider, feature,
  option, and support state are pattern-matchable.
- `CliSubprocessCore.EphemeralFile`, a provider-neutral exclusive `0600`
  temporary-file primitive with owner monitoring and idempotent bounded
  teardown.
- Dependency-source helper v6 release edges from `antigravity_cli_sdk` and
  `amp_sdk` to `cli_subprocess_core`.

### Changed

- Amp and Antigravity now reject unsupported schema and completion-only intent
  before resolving or starting their CLIs. Ordinary invocations are unchanged.
- `OutputSchemaFile` delegates secure materialization to the generic primitive
  while preserving its JSON validation and public error contract.
- Amp result projection preserves provider result text, status/subtype,
  durations, turns, usage totals, cost, and permission denials. Antigravity
  keeps non-empty provider output byte-faithful.

### Fixed

- Removed redundant clauses diagnosed by Elixir 1.20 so the
  warnings-as-errors build remains green on the current release toolchain.

## [0.3.0] - 2026-07-27

### Added

- `Payload.Result.object` carries a provider-returned structured object. The
  Claude profile lifts `structured_output` off the result frame; the Codex
  profile decodes the schema-constrained final agent message, and only when the
  run actually requested a schema. A reply that is not JSON leaves the field
  `nil` rather than manufacturing an object. Amp, Cursor, and the synthetic exit
  result declare the field explicitly empty because no structured-output
  surface is proven for them.
- `CliSubprocessCore.OutputSchemaFile` and `CliSubprocessCore.EphemeralFiles`:
  an owner-monitored lifecycle for temporary files an invocation needs on disk.
  `ProviderProfile.build_invocation/1` may now return
  `{:ok, invocation, teardown}`; `Command.run/1` and `Session` run that teardown
  on a normal result, an error, an interrupt, and a close, while
  `EphemeralFiles` removes the file when the owning process is killed
  untrappably and never gets to run it.
- A completion-only invocation profile (`completion_only: true`). Claude
  receives an empty tool set, plan permission mode, no settings sources, and
  strict MCP config. Codex receives a read-only sandbox, ephemeral operation,
  no user config or rules, disabled web search and skills, and an
  `approval_policy="never"` config override. Both replace, rather than merge
  with, caller-supplied permission state.

### Fixed

- Publish preflight now requires the exact sibling version developed against
  to exist on Hex. An older package release can no longer mask a missing
  current release, as the historical `execution_plane 0.1.0` monolith did for
  the core-only `execution_plane 0.2.0`. Nested package tasks resolve the
  helper-owning repository, and a manifest self-entry is not treated as a
  circular prerequisite.
- `--output-schema` now receives a **file path**. `codex exec` types the flag as
  a path and exits non-zero when it cannot read the file, so the previous inline
  JSON encoding was a hard failure rather than a degraded mode.
- `transport_headless_timeout_ms` reaches the transport. Without the alias the
  declared orphan-reap window was silently replaced by the transport's own 30 s
  default, letting a subprocess outlive its owner by 25 s longer than the
  contract allows.
- Output-schema files use an OS-process-qualified, exclusive 0600 namespace,
  reject cross-owner tracking collisions, and are proven to disappear through
  every public command/session terminal path.

### Changed

- Require the core-only `execution_plane ~> 0.2.0`; the historical 0.1.0 Hex
  package bundled the same process and JSON-RPC modules now supplied by the
  canonical component dependencies.
- Refreshed the `zoi` lock from 0.18.5 to 0.18.7.
- The shared Claude catalog advertises **Opus 5**. Both `opus` and the retained
  compatibility choice `opus[1m]` list `claude-opus-5`; Opus 5 is itself a
  1M-context model, so no suffixed provider id is invented. Prior full ids
  (`claude-opus-4-8`, `claude-opus-4-7`) remain resolvable, matching how the
  Sonnet entry retains `claude-sonnet-4-6`.

## [0.2.0] - 2026-07-13

### Added

- Current Codex GPT-5.6 Sol, Terra, and Luna catalog entries plus the public
  GPT-5.3-Codex-Spark ChatGPT Pro preview, including model-specific reasoning
  defaults and `max`/`ultra` validation.
- Cursor Agent CLI (`:cursor`) first-party provider profile with stream-json
  parsing, live fixture evidence, model catalog entries, and provider feature
  metadata.
- Documentation updates for Cursor as the fifth built-in profile, including
  invocation shape, permission metadata, governed posture, and capability hints.
- Atom-safety guardrail: `.credo.exs` with `Credo.Check.Warning.UnsafeToAtom`
  enabled (scoped to `lib/`) plus a `scripts/atom_guard.sh` CI backstop wired
  into `mix ci` (which now runs `credo --strict`).
- Secrets guardrail: `scripts/secrets_guard.sh` in `mix ci`; `.env` files
  gitignored.
- README documents registry ownership and hex publish-ordering: this package
  publishes first, then `claude_agent_sdk` / `agent_session_manager`.

### Changed

- Restricted the Hex archive to runtime source, model data, dependency-source
  support, consumer guides/examples, and public release documentation/assets.
- Replaced separate Execution Plane core, JSON-RPC, and process package
  dependencies with the single generated `execution_plane ~> 0.1.0` package.
- Local development now consumes the generated monolith artifact and clean
  clones fall back to the durable `projection/execution_plane` branch.
- The Codex catalog now follows an authenticated live `codex-cli 0.144.1`
  `model/list` probe from 2026-07-10: `gpt-5.6-sol` is the default, Spark is
  public but non-API, `codex-auto-review` remains internal, and backend-absent
  `gpt-5.2` stays excluded.
- Refreshed compatible dependencies, including Zoi 0.18.5.

### Security

- `Command` env validation returns offending **keys** (or `:not_a_map`) in
  `{:invalid_env, ...}` error tuples instead of echoing the full env map,
  whose values routinely include credentials.

### Removed

- Retired the Gemini CLI profile, catalog, discovery/fallback path, feature
  manifest, and model-selection workflow target. Google coding-agent support
  now uses the Antigravity profile only.

## [0.1.0] - 2026-04-06

### Added

- Initial release.
- Governed CLI launch authority for command, cwd, env, config-root, auth-root,
  base-URL, target, and clear-env materialization without ambient provider CLI
  env discovery.

[Unreleased]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nshkrdotcom/cli_subprocess_core/releases/tag/v0.1.0
