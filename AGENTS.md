# AGENTS.md

## Local execution guidance for this repo

Use the local model-selection script for workflow validation:
- `./scripts/model_selection_ci.sh ci`
- `./scripts/model_selection_ci.sh all --repo cli_subprocess_core`
- `./scripts/model_selection_ci.sh test --tag sdk`

## Execution Plane stack rules

- This repo is the CLI family kit above `execution_plane`; it owns provider CLI planning, command/session semantics, recovery envelopes, and facade surfaces.
- Downstream provider SDKs should consume `CliSubprocessCore.*` facades such as `ExecutionSurface`, `TransportError`, `TransportInfo`, and `ProcessExit`, not raw `ExecutionPlane.*` modules.
- Keep local sibling deps publish-aware. Local development uses
  `build_support/dependency_sources.exs` and
  `build_support/dependency_sources.config.exs`. Committed default dependency
  priority is `GitHub -> Hex -> path` so clean downstream Git checkouts do not
  silently bind to sibling `deps/` directories. Local path development uses
  `.dependency_sources.local.exs` to select
  `../execution_plane/core/execution_plane` for `:execution_plane`; lane deps
  still use their package homes such as
  `../execution_plane/protocols/execution_plane_jsonrpc` and
  `../execution_plane/runtimes/execution_plane_process`. Hex builds must
  resolve Execution Plane packages by version.
- Local dependency overrides use `.dependency_sources.local.exs`.
- Default dependency priority is `GitHub -> Hex -> path`; publish mode is
  Hex-only and must fail with exact blockers if an internal dep is unavailable
  on Hex.
- Dependency source selection must not use environment variables.
- Weld maintains helper drift, manifests, clone checks, publish checks, and
  publish order, but this repo is not a Weld consumer in this pass and must not
  receive a blind Weld dependency.
- Do not point `:execution_plane` at the sibling repo root. That root is the
  non-published Blitz workspace project, not the Hex package.
- Runtime application code under `lib/**` must not call direct OS env APIs such
  as `System.get_env`, `System.fetch_env`, `System.put_env`, or
  `System.delete_env`.
- Runtime and deployment env reads belong in `config/runtime.exs` or an
  explicit `Config.Provider`.
- Library APIs receive explicit options, config structs, credential providers,
  application config materialized by the top-level app, or caller-supplied env
  maps.
- Tests may manipulate env only for config-boundary, SDK compatibility, or
  live-wrapper checks.
- Live provider commands use `~/scripts/with_bash_secrets <command>` and must
  not print secrets.
- Full gate: `mix ci`, plus the model-selection script when model catalog behavior changes.
