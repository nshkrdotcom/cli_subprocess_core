# model_selection_ci.sh

Use this script to run model-selection-related quality gates from `/home/home/p/g/n/cli_subprocess_core`.

## What it does

- Enforces a strict repo allowlist:
  - `cli_subprocess_core`
  - `agent_session_manager`
  - `codex_sdk`
  - `gemini_cli_sdk`
  - `claude_agent_sdk`
  - `amp_sdk`
- Supports the tasks:
  - `format` -> `mix format --check-formatted`
  - `compile` -> `mix compile`
  - `test` -> `mix test`
  - `credo` -> `MIX_ENV=test mix credo --strict`
  - `dialyzer` -> `MIX_ENV=dev mix dialyzer`
  - `all` -> run all five tasks in order
  - `ci` -> alias for `all` across all six repos
- Fails hard on first failure.
- Prints repo-by-repo pass/fail status and final summary.
- Supports focused execution with `--repo` and `--tag`.

## Usage examples

- Run full workflow on all six repos:
  - `./scripts/model_selection_ci.sh ci`
- Run all checks on one repo:
  - `./scripts/model_selection_ci.sh all --repo cli_subprocess_core`
- Run compile only on two repos:
  - `./scripts/model_selection_ci.sh compile --repo codex_sdk,amp_sdk`
- Run model-related checks for the SDK group:
  - `./scripts/model_selection_ci.sh all --tag sdk`

## Supported repo aliases

- `core` -> `cli_subprocess_core`
- `asm` -> `agent_session_manager`
- `codex` -> `codex_sdk`
- `gemini` -> `gemini_cli_sdk`
- `claude` -> `claude_agent_sdk`
- `amp` -> `amp_sdk`
