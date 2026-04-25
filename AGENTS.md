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
  `../execution_plane/core/execution_plane` for `:execution_plane`; lane deps
  still use their package homes such as
  `../execution_plane/protocols/execution_plane_jsonrpc` and
  `../execution_plane/runtimes/execution_plane_process`. Hex builds must
  resolve Execution Plane packages by version.
- Do not point `:execution_plane` at the sibling repo root. That root is the
  non-published Blitz workspace project, not the Hex package.
- Full gate: `mix ci`, plus the model-selection script when model catalog behavior changes.
