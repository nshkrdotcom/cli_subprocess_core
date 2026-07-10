# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-07-10

### Added

- Current Codex GPT-5.6 Sol, Terra, and Luna catalog entries plus the public
  GPT-5.3-Codex-Spark ChatGPT Pro preview, including model-specific reasoning
  defaults and `max`/`ultra` validation.
- Cursor Agent CLI (`:cursor`) first-party provider profile with stream-json
  parsing, live fixture evidence, model catalog entries, and provider feature
  metadata.
- Documentation updates for Cursor as the fifth built-in profile, including
  invocation shape, permission metadata, governed posture, and capability hints.

### Changed

- The Codex catalog now follows an authenticated live `codex-cli 0.144.1`
  `model/list` probe from 2026-07-10: `gpt-5.6-sol` is the default, Spark is
  public but non-API, `codex-auto-review` remains internal, and backend-absent
  `gpt-5.2` stays excluded.
- Refreshed compatible dependencies, including Zoi 0.18.5.

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
