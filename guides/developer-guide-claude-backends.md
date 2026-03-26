# Developer Guide: Claude Backends

This guide explains the Claude-specific backend path owned by
`/home/home/p/g/n/cli_subprocess_core`.

It is for maintainers of:

- `/home/home/p/g/n/cli_subprocess_core`
- `/home/home/p/g/n/claude_agent_sdk`
- `/home/home/p/g/n/agent_session_manager`

## Why This Exists

Claude is no longer only a static catalog problem.

The core still owns the canonical Claude catalog in:

- `/home/home/p/g/n/cli_subprocess_core/priv/models/claude.json`

But the core also owns an explicit Claude backend selector:

- `:anthropic`
- `:ollama`

That decision belongs in core because both direct core sessions and ASM resolve
Claude model payloads through `CliSubprocessCore.ModelRegistry`.

## Backend Sequence

For Claude, resolution now happens in this order:

1. choose the backend
2. choose the requested model source
3. validate the target model for that backend
4. build one authoritative selection payload
5. let downstream code only format CLI arguments and env

The important split is:

- core chooses the backend and model policy
- provider renderers only emit `claude ... --model ...`

## Anthropic Backend

`provider_backend: :anthropic` is the default.

It uses the static Claude catalog and preserves the normal resolution flow:

1. explicit request
2. env override
3. provider default
4. remote default
5. hard failure

## Ollama Backend

`provider_backend: :ollama` is explicit.

It does not use a silent default model.

That means:

- explicit or env-driven model selection is required
- `default_model/2` hard-fails for Claude/Ollama
- core validates the external target against the Ollama API before building the
  payload

The live Ollama integration points are:

- `/home/home/p/g/n/cli_subprocess_core/lib/cli_subprocess_core/ollama.ex`
- `/home/home/p/g/n/cli_subprocess_core/lib/cli_subprocess_core/model_registry.ex`

## Canonical Claude Names Versus External Models

The Ollama path supports two request styles.

### Direct external model id

Example:

```elixir
CliSubprocessCore.ModelRegistry.build_arg_payload(
  :claude,
  "llama3.2",
  provider_backend: :ollama,
  anthropic_base_url: "http://localhost:11434"
)
```

That resolves directly to the external model id.

### Canonical Claude name mapped to an external model

Example:

```elixir
CliSubprocessCore.ModelRegistry.build_arg_payload(
  :claude,
  "haiku",
  provider_backend: :ollama,
  anthropic_base_url: "http://localhost:11434",
  external_model_overrides: %{"haiku" => "llama3.2"}
)
```

That keeps the caller on the canonical Claude naming surface while the payload
resolves the transport model to `llama3.2`.

This is the path that lets existing Claude-focused code keep asking for
`haiku`, `sonnet`, or `opus` while a local Ollama model actually runs.

## Payload Fields That Matter

For Claude/Ollama, the selection payload now carries more than `resolved_model`.

Important fields:

- `provider_backend`
- `model_source`
- `resolved_model`
- `env_overrides`
- `settings_patch`
- `backend_metadata`

In practical terms:

- `resolved_model` is what the renderer passes to `--model`
- `env_overrides` contains the Anthropic-compatible Ollama env
- `backend_metadata` carries backend-specific facts such as the requested model,
  external model, Ollama details, and capabilities

## What “Render Transport Arguments” Means Here

It only means this:

1. core resolves policy into payload
2. the Claude profile or SDK reads the payload
3. they emit the final CLI command and env

For Claude/Ollama that becomes:

- command: `claude`
- args: `--model <resolved_model>`
- env:
  - `ANTHROPIC_AUTH_TOKEN=ollama`
  - `ANTHROPIC_API_KEY=""`
  - `ANTHROPIC_BASE_URL=http://localhost:11434`

No downstream layer decides the backend again.

## Repo Responsibilities

`/home/home/p/g/n/cli_subprocess_core`

- owns backend choice
- owns Claude static catalog
- owns Ollama validation
- owns payload fields consumed by downstream repos

`/home/home/p/g/n/claude_agent_sdk`

- resolves through the core payload
- merges payload env/settings into the CLI request
- does not implement a second model-policy path

`/home/home/p/g/n/agent_session_manager`

- forwards Claude backend fields into core resolution
- attaches the resolved payload
- keeps provider schemas as value carriers only

## Reviewer Checklist

When reviewing Claude backend changes, verify:

- Claude backend selection still enters through `CliSubprocessCore.ModelRegistry`
- `:ollama` has no silent default model
- external model validation still happens in core
- downstream repos only consume payload fields
- no code path emits `--model nil`, `--model null`, or `--model ""`
