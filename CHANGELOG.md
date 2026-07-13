# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
