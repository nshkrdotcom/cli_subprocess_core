# AGENTS.md

## Local execution guidance for this repo

Use the local model-selection script for workflow validation:
- `./scripts/model_selection_ci.sh ci`
- `./scripts/model_selection_ci.sh all --repo cli_subprocess_core`
- `./scripts/model_selection_ci.sh test --tag sdk`

## Execution Plane stack rules

- This repo is the CLI family kit above `execution_plane`; it owns provider CLI planning, command/session semantics, recovery envelopes, and facade surfaces.
- Downstream provider SDKs should consume `CliSubprocessCore.*` facades such as `ExecutionSurface`, `TransportError`, `TransportInfo`, and `ProcessExit`, not raw `ExecutionPlane.*` modules.
- Keep local sibling deps publish-aware. Local development may use `../execution_plane`; Hex builds must resolve `execution_plane` by version.
- Full gate: `mix ci`, plus the model-selection script when model catalog behavior changes.
