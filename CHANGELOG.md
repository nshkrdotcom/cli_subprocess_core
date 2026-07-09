# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-07-09

### Added

- Current Codex GPT-5.6 Sol, Terra, and Luna catalog entries, including
  model-specific `max` and `ultra` reasoning-effort validation.
- Cursor Agent CLI (`:cursor`) first-party provider profile with stream-json
  parsing, live fixture evidence, model catalog entries, and provider feature
  metadata.
- Documentation updates for Cursor as the fifth built-in profile, including
  invocation shape, permission metadata, governed posture, and capability hints.

### Changed

- The Codex catalog now follows an authenticated live `codex-cli 0.144.0`
  `model/list` probe from 2026-07-09: `gpt-5.5` remains the default, the three
  explicit GPT-5.6 variants are public, `codex-auto-review` remains internal,
  and backend-absent `gpt-5.2` stays excluded.
- Refreshed compatible dependencies, including Zoi 0.18.5.

## [0.1.0] - 2026-04-06

### Added

- Initial release.
- Governed CLI launch authority for command, cwd, env, config-root, auth-root,
  base-URL, target, and clear-env materialization without ambient provider CLI
  env discovery.
