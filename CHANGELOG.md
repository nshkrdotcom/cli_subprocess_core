# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.0] - 2026-08-10

### Fixed

- Classify exhausted provider credits and quota as the terminal
  `provider_quota_exhausted` recovery class, even when a CLI labels the error
  `unknown`. These failures cannot be repaired by another prompt or by an
  immediate retry; ordinary `rate_limit` errors remain bounded and retryable.
- Make the first-party model catalogs available from installed escripts.
  `ModelCatalog` previously read only `Application.app_dir/2` paths. Inside an
  escript that path traverses the archive as though it were a directory, so
  every provider failed before launch with `{:not_found, :enotdir}`. Catalog
  JSON is now tracked and embedded at compile time, with filesystem-first
  loading and an embedded fallback. A regression test exercises the exact
  file-as-parent `:enotdir` shape while retaining the fail-closed error for an
  unknown provider.

## [0.6.0] - 2026-08-10

### Added

- `CliSubprocessCore.ProviderProfile.accepts_input_after_start?/1`: whether a
  lane can actually be handed more input once its run has started. The answer
  requires an open stdin and an explicit `:incremental_input` capability; no
  shipped profile currently declares it, so current lanes interrupt and resume
  instead. `capabilities/0` alone cannot distinguish the mechanisms.

### Changed

- The two governed-binding validators in `RuntimeGateway.Local` and
  `RuntimeGateway.RuntimeClient` are ordered rule lists rather than duplicated
  `cond` chains. Same comparisons, same reason codes, same short-circuit: one
  row per ref, so adding a ref means adding a row.

### Fixed

- Require `execution_plane_jsonrpc ~> 0.2.0`, the first JSON-RPC component
  release compatible with the core-only `execution_plane ~> 0.3.0` line.

- `ProviderProfile.accepts_input_after_start?/1` no longer reports `claude` as
  accepting live input. It derived the answer from `close_stdin_on_start?`
  alone, and an open file descriptor is not a reader: `claude --print` takes
  its prompt on argv, consumes stdin once while assembling it, and never reads
  it again. A caller acting on that answer had its message silently swallowed
  while every layer above reported success. The answer now requires both an
  open stdin and a profile declaring `:incremental_input`. No shipped profile
  declares it, so every lane is steered by interrupt and resume. Verified
  against the shipping CLI: text piped before the turn changes the answer, the
  same text written eight seconds in does not.
- The Claude profile decodes tool calls. `claude --output-format stream-json`
  does not emit top-level `tool_use` or `tool_result` events — it emits
  Anthropic messages, with a `tool_use` block inside an `assistant` message's
  content and its result inside the next `user` message. The profile handled
  only the top-level shapes, which the shipping CLI never produces, and had no
  handler for `user` at all. A Claude run that edited a dozen files therefore
  decoded as a dozen assistant messages with empty content, reported zero
  tools, and dropped every tool result as an unrecognized raw event.

  An `assistant` message now emits one event per content block, in block order:
  `tool_use` blocks become `:tool_use`, `thinking` blocks become `:thinking`,
  and text blocks become `:assistant_message`. A `user` message emits
  `:tool_result` per `tool_result` block, keyed by `tool_use_id`, with content
  blocks flattened to text. The top-level handlers are kept for older builds
  and hand-written fixtures.

  Consumers should expect `:thinking` events from Claude where none arrived
  before: they were previously swallowed inside the assistant message, not
  absent.

## [0.5.1] - 2026-08-10

### Fixed

- Make the published package loadable by any consumer. `mix.exs` required
  `build_support/dependency_sources.exs`, which the package does not ship, so
  `mix compile` in a consuming project died while Mix loaded this dependency's
  project. It now detects a source checkout by that file's presence: in a
  checkout the registry resolves siblings path-first as before, and in a
  published package the Hex requirements stated in `mix.exs` are the whole
  answer. 0.5.0 is retired.

## [0.5.0] - 2026-08-10

Two provider profiles were written against event schemas their CLIs do not
produce. Neither failed loudly; both simply reported that nothing happened.

### Changed

- **The Antigravity profile now requests `--output-format stream-json`.** It
  previously ran `agy --print`, whose plain-text output was normalized one line
  at a time into assistant deltas — so a run produced text and nothing else: no
  tool calls, no token usage, no terminal result. `agy` reports a run as
  numbered steps that go `ACTIVE` then `DONE`, which supplies both halves of a
  tool call. A stdout line that is not JSON is still emitted as an assistant
  delta, so `output_format: "text"` and older CLIs keep working.
- Codex and Antigravity tool names and parameter keys are translated to the
  spellings consumers already use for other providers: a shell command is
  `Bash` carrying a `command`, a file edit is `Edit` carrying a `file_path`.
  Renderers and tool allowlists both key off these names, so a
  provider-specific spelling renders correctly while silently matching no
  allowlist entry.

### Added

- The Codex profile decodes the item types `codex exec --json` actually emits:
  `command_execution`, `file_change`, `mcp_tool_call`, `web_search` and
  `todo_list`. It previously looked for item types named `tool_call` and
  `tool_result`, which the CLI has never emitted, so every tool call fell
  through to `:raw` and no consumer could see that the model had done anything.
  The older names are still accepted.
- `item.started` is decoded as `tool_use`, giving a live signal that a tool has
  begun rather than only that it finished. Both halves carry the item's `id`,
  which is what pairs a call with its result.

### Fixed

- `turn.failed` is decoded, emitting both an error and a terminal result. It
  was previously unmapped, so a failed Codex turn produced no stop reason at
  all and a consumer waiting on one waited indefinitely.
- `normalize_session_id/1` treated `nil` as an atom — which it is — and
  returned the string `"nil"`. That value then overwrote the real provider
  session id on every event that did not carry one, so only the first event of
  a run held it. Every resume path reads that id back, and would have resumed a
  thread named `"nil"`.
- The local runtime gateway derived an error's `ambiguous` flag by comparing its
  category against `:ambiguous`, a value that category can never hold — the
  gateway resolves every outcome it reports. `Error.new/1` enforces
  `ambiguous == (category == "ambiguous")`, so the flag is now stated directly.

### Removed

- Unreachable clauses in the runtime gateways, each proved dead by the type
  rather than by inspection: the `clear_env?` guard in both `Local` and
  `RuntimeClient` session-binding validation, since `GovernedAuthority` types
  that field as the literal `true` and enforces it in `validate_clear_env/1`; a
  non-map head of `metadata_value/2` whose argument comes from a map-typed
  `%Options{}` field; and a third `normalize_runtime_reply/1` head for a reply
  shape the runtime does not produce.

The package is Dialyzer- and Credo-clean with no ignore entries.

## [0.4.1] - 2026-07-27

### Fixed

- The Claude profile now emits `--effort` from the shared model registry's
  normalized `model_payload.reasoning`. Previously Claude effort was validated
  and preserved in the payload, then silently dropped by the direct CLI lane.

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
- Keep the opaque transport-error matcher dynamically callable after a
  downstream function has excluded generic exceptions. This prevents Elixir
  1.20 from over-refining valid facade calls to an always-false branch while
  preserving the lower transport struct boundary.

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

[Unreleased]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nshkrdotcom/cli_subprocess_core/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nshkrdotcom/cli_subprocess_core/releases/tag/v0.1.0
