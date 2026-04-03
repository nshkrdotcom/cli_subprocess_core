# Developer Guide: Codex Backends

This guide explains the backend-aware Codex path owned by
`cli_subprocess_core`.

## Why Codex Needs Backend Metadata

Codex does not have a single backend shape.

The upstream CLI distinguishes:

- the default OpenAI path
- OSS mode
- the selected OSS provider
- model-provider routing

The core keeps those concepts intact instead of flattening everything into one
generic external-model switch.

## Current Backend Contract

For provider `:codex`, the core selection payload carries:

- `provider_backend: :openai | :oss | :model_provider`
- `backend_metadata["oss_provider"]` for OSS routing
- `backend_metadata["model_provider"]` for model-provider routing

For the current local Ollama path, the contract is:

- `provider_backend: :oss`
- `backend_metadata["oss_provider"] = "ollama"`

## Live CLI Assumption Check

This backend path was validated against the installed tools before the Elixir
implementation landed:

- `codex-cli 0.116.0`
- `ollama 0.18.2`

Direct CLI check:

```bash
codex exec --json \
  --config 'model_provider="ollama"' \
  --config 'model="gpt-oss:20b"' \
  "Respond with exactly: OK"
```

The more general local route also runs with arbitrary installed models such as
`llama3.2`:

```bash
codex exec --json \
  --config 'model_provider="ollama"' \
  --config 'model="llama3.2"' \
  "Respond with exactly: OK"
```

Upstream does not hard-reject that model. Instead, when the slug is missing
from Codex's own model metadata catalog, the CLI warns and uses fallback model
metadata. That distinction matters:

- `gpt-oss:20b` is the default validated OSS model
- arbitrary Ollama models can still run
- fallback metadata can degrade behavior on those non-catalog models

## What Core Owns

`CliSubprocessCore.ModelRegistry` owns:

- validating the requested Codex backend
- validating that the selected OSS provider is supported
- validating Ollama availability and minimum version
- validating the external model id
- choosing the effective default model for the backend
- returning the resolved payload consumed by downstream renderers

`CliSubprocessCore.Ollama` owns the actual HTTP checks used by the Codex OSS
path:

- version lookup
- installed-model lookup
- running-model lookup
- model-detail validation

## Current Ollama Rules

The current long-term supported Codex external path is local Ollama.

Core rules:

- minimum Ollama version: `0.13.4`
- default Codex OSS model: `gpt-oss:20b`
- arbitrary installed Ollama models are accepted on the shared Codex/Ollama
  route
- explicit local provider required conceptually, even though the current core
  defaults the OSS provider to `ollama` for the local path
- model ids are validated through Ollama before the payload is returned
- the feature manifest records which models are the validated defaults, not a
  hard allowlist
- non-default models may still trigger upstream fallback metadata behavior

The resolved payload includes:

- `resolved_model`
- `reasoning`
- `provider_backend`
- `backend_metadata["oss_provider"]`
- `backend_metadata["loaded"]`
- `backend_metadata["support_tier"]`
- model-family and catalog visibility fields

## Downstream Consumption

Downstream repos do not make a second backend decision.

In this stack:

- `CliSubprocessCore.ProviderProfiles.Codex` renders payload-owned `--config`
  overrides for `model_provider` and `model` on the local Ollama path, and
  closes stdin on start for one-shot exec runs so upstream Codex does not wait
  for EOF after argv prompts
- `/home/home/p/g/n/codex_sdk` reads the same payload in
  `Codex.Options`, `Codex.Runtime.Exec`, and app-server startup
- `/home/home/p/g/n/agent_session_manager` forwards Codex backend intent into
  the core registry and passes the resolved payload through unchanged

## Example

```elixir
{:ok, selection} =
  CliSubprocessCore.ModelRegistry.build_arg_payload(
    :codex,
    "gpt-oss:20b",
    provider_backend: :oss,
    oss_provider: "ollama"
  )

selection.provider_backend
# => :oss

selection.backend_metadata["oss_provider"]
# => "ollama"
```

## Reviewer Checklist

When reviewing Codex backend changes, verify:

- backend policy stays in `CliSubprocessCore.ModelRegistry`
- provider renderers only read payload fields
- local Ollama validation stays explicit and hard-failing
- validated defaults stay metadata, not an invented hard allowlist
- blank or placeholder model ids still fail
- no renderer emits stale Codex OSS argv flags when the upstream CLI expects
  config-driven model-provider routing
