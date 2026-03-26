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
codex exec --oss --local-provider ollama -m llama3.2 "Respond with exactly: OK"
```

That path succeeded locally, so the core implementation is aligned to the
actual checked-out CLI behavior rather than a guessed abstraction.

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
- explicit local provider required conceptually, even though the current core
  defaults the OSS provider to `ollama` for the supported local path
- model ids are validated through Ollama before the payload is returned

The resolved payload includes:

- `resolved_model`
- `reasoning`
- `provider_backend`
- `backend_metadata["oss_provider"]`
- `backend_metadata["loaded"]`
- model-family and catalog visibility fields

## Downstream Consumption

Downstream repos do not make a second backend decision.

In this stack:

- `CliSubprocessCore.ProviderProfiles.Codex` renders `--oss`,
  `--local-provider`, and `--model` from the payload
- `/home/home/p/g/n/codex_sdk` reads the same payload in
  `Codex.Options`, `Codex.Runtime.Exec`, and app-server startup
- `/home/home/p/g/n/agent_session_manager` forwards Codex backend intent into
  the core registry and passes the resolved payload through unchanged

## Example

```elixir
{:ok, selection} =
  CliSubprocessCore.ModelRegistry.build_arg_payload(
    :codex,
    "llama3.2",
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
- blank or placeholder model ids still fail
- no renderer emits synthetic Codex backend flags without payload support
