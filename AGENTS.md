# AGENTS.md

## Local execution guidance for this repo

Use the local model-selection script for workflow validation:
- `./scripts/model_selection_ci.sh ci`
- `./scripts/model_selection_ci.sh all --repo cli_subprocess_core`
- `./scripts/model_selection_ci.sh test --tag sdk`

## Execution Plane stack rules

- This repo is the CLI family kit above `execution_plane`; it owns provider CLI planning, command/session semantics, recovery envelopes, and facade surfaces.
- First-party profiles currently shipped here: Claude, Codex, Cursor, Amp, and
  Antigravity. Google coding-agent support is Antigravity-only.
- Downstream provider SDKs should consume `CliSubprocessCore.*` facades such as `ExecutionSurface`, `TransportError`, `TransportInfo`, and `ProcessExit`, not raw `ExecutionPlane.*` modules.
- Keep local sibling deps publish-aware. Local development uses
  `build_support/dependency_sources.exs` and
  `build_support/dependency_sources.config.exs`. Committed default dependency
  priority is `path -> GitHub -> Hex` so local sibling checkouts resolve
  consistently across downstream workspaces while clean standalone clones fall
  back to GitHub. This repo pins the three canonical Execution Plane components
  — `core/execution_plane`, `runtimes/execution_plane_process`, and
  `protocols/execution_plane_jsonrpc` — by path, by GitHub `subdir`, and by Hex
  version.
- Local dependency overrides use `.dependency_sources.local.exs`.
- Default dependency priority is `path -> GitHub -> Hex`; publish mode is
  Hex-only and must fail with exact blockers if an internal dep is unavailable
  on Hex.
- Dependency source selection must not use environment variables.
- Weld owns the upstream generated artifact and durable projection branch.
  This consumer keeps its dependency-source helper thin and must not add a
  second projection mechanism.
- Do not point `:execution_plane` at the generated
  `../execution_plane/dist/monolith/execution_plane` artifact. `mix` unifies
  dependencies by APP NAME, and `:execution_plane` names two different
  packages: the core-only component, and that monolith which bundles core +
  process + JSON-RPC under the same name. Every sibling repository that
  declares Execution Plane — `jido_integration`, `citadel`, `pristine`,
  `llama_cpp_sdk`, `mezzanine`, `switchyard`, `reqllm_next`, `jido_hive`,
  `self_hosted_inference_core` — pins the canonical components, so a graph
  containing this package and any of them resolves only if this package pins
  them too. Choosing the monolith makes `mix deps.get` refuse the combined
  graph; and `ExecutionPlane.Process.Transport.Surface`, which
  `execution_surface.ex` calls at compile time, then resolves against a
  core-only package that does not contain it.
- Do not point `:execution_plane` at the sibling source repo root.
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

## Design intent — stay a thin seam

- This repo is a *planning/semantics* seam over `execution_plane`, not an
  execution engine. It delegates every real subprocess to
  `ExecutionPlane.Process.Transport` / `ExecutionPlaneProcess.execute` and must
  not spawn OS processes itself. `json_rpc.ex` is deliberately a `defdelegate`
  to `ExecutionPlane.Protocols.JsonRpc.Adapter`.
- The eventuality is that `execution_plane` runs as a separate, hard-isolated
  BEAM node for effect isolation (see execution_plane/AGENTS.md → *Design Intent
  — Effect Isolation*). Keeping this repo a thin delegating seam (facades +
  model policy + command/session semantics) is what lets that node separation
  happen with zero changes here.
- Do **not** vendor or re-absorb Execution Plane's transport to shorten the
  dependency chain for publishing — that re-couples the effect mechanics into
  the CLI core and defeats the isolation goal. If publish-time decoupling from
  the plane is ever required, do it via an optional dep + explicit fallback
  transport, not by copying the mechanics.
