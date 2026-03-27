# Developer Guide: Model Registry and Provider Catalogs

This guide explains how model selection works inside `cli_subprocess_core`.
It is written for maintainers and technical reviewers of the core itself.

## Why the Model Registry Exists

`cli_subprocess_core` owns model policy for the shared CLI stack.

That means the core decides:

- which provider catalog is authoritative
- how requested models are resolved
- how provider defaults are chosen
- how reasoning effort is validated
- which visible error contract downstream code receives

Consumer repos should not re-implement any of those decisions.

## The Core Files

The model-selection internals live in:

- `lib/cli_subprocess_core/model_catalog.ex`
- `lib/cli_subprocess_core/model_registry.ex`
- `lib/cli_subprocess_core/model_registry/model.ex`
- `lib/cli_subprocess_core/model_registry/selection.ex`
- `lib/cli_subprocess_core/ollama.ex`
- `priv/models/codex.json`
- `priv/models/claude.json`
- `priv/models/gemini.json`
- `priv/models/amp.json`

## What the Catalogs Contain

Each provider catalog is a core-owned source of truth.

For Gemini and Amp, that source is static JSON only.

For Claude and Codex, the source is split:

- static core catalog for the canonical Claude model surface
- explicit backend-aware external validation for the Ollama path
- static core catalog for the canonical Codex/OpenAI model surface
- explicit backend-aware external validation for the Codex local OSS/Ollama
  path

The static catalog defines, per model:

- `id`
- `aliases`
- `visibility`
- `family`
- whether it is the provider default
- optional reasoning-effort mappings
- provider metadata

This gives the core one place to answer:

- “is this model known?”
- “what is the default?”
- “what visibilities are exposed?”
- “which reasoning values are valid for this model?”

## Resolution Sequence

The authoritative resolution order is:

1. explicit request
2. environment override
3. provider default
4. remote default
5. hard failure

That resolution happens in `CliSubprocessCore.ModelRegistry.resolve/3`.

The output is a resolved selection that includes:

- provider
- requested model
- resolved model
- resolution source
- provider backend
- model source
- payload env overrides
- backend metadata
- reasoning and normalized reasoning effort
- model family
- catalog version
- visibility
- error list

## Validation Responsibilities

The registry has separate responsibilities that should stay separate:

- `resolve/3` chooses the final model and backend path
- `validate/2` checks whether a requested model is valid for the resolved backend
- `default_model/2` reads the effective provider default
- `normalize_reasoning_effort/3` validates reasoning input against the chosen
  model
- `build_arg_payload/3` returns the resolved selection used by provider command
  builders

That separation matters because downstream code often needs one of those steps
without needing the entire resolution flow.

## Error Contract

The core exposes a single visible error vocabulary:

- `{:error, {:unknown_model, requested_model, suggestions, provider}}`
- `{:error, {:invalid_reasoning_effort, requested, allowed, provider}}`
- `{:error, {:model_unavailable, provider, reason}}`
- `{:error, {:empty_or_invalid_model, reason, provider}}`

This is important for maintainability. The provider profiles and consumer repos
can handle a stable contract instead of inventing provider-specific error rules.

## Where the Selection Is Used

After the registry resolves the model, the built-in provider profiles read that
selection and format CLI arguments and env.

The provider profiles are:

- `lib/cli_subprocess_core/provider_profiles/codex.ex`
- `lib/cli_subprocess_core/provider_profiles/claude.ex`
- `lib/cli_subprocess_core/provider_profiles/gemini.ex`
- `lib/cli_subprocess_core/provider_profiles/amp.ex`

Those modules should not make a second policy decision. Their job is to turn
the resolved selection into transport arguments such as `--model ...` and the
backend-owned env attached to the payload.

## Minimal Integration Example

An integrating caller should do this:

```elixir
{:ok, selection} =
  CliSubprocessCore.ModelRegistry.build_arg_payload(
    :codex,
    "gpt-5.4",
    reasoning_effort: :medium
  )

selection.resolved_model
# => "gpt-5.4"
```

After that, provider-specific command building can safely use the resolved
selection without re-deciding the model.

When a caller may receive either raw model knobs or an already-resolved
selection, use `CliSubprocessCore.ModelInput.normalize/3` as the canonical
mixed-input boundary. It accepts raw attrs or `model_payload`, validates
consistency when both are present, and returns normalized attrs with the
authoritative payload attached.

Across the current first-party provider SDK repos, that means:

- `claude_agent_sdk`, `codex_sdk`, and `gemini_cli_sdk` should route mixed
  raw-versus-payload model input through `CliSubprocessCore.ModelInput`
- repo-local env defaults are fallback inputs only when no explicit payload was
  supplied
- `amp_sdk` is intentionally different today because it does not expose a raw
  model-selection surface; it carries an optional payload-only model contract
  instead of inventing a second model-input path

For Claude/Ollama, a caller can keep canonical Claude names while mapping them
to an installed external model:

```elixir
{:ok, selection} =
  CliSubprocessCore.ModelRegistry.build_arg_payload(
    :claude,
    "haiku",
    provider_backend: :ollama,
    anthropic_base_url: "http://localhost:11434",
    external_model_overrides: %{"haiku" => "llama3.2"}
  )

selection.resolved_model
# => "llama3.2"
```

For Codex local OSS via Ollama, the caller should pass the backend intent into
the core and let the registry validate that the local model exists:

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
```

If the local model is not one of Codex's validated defaults, the shared core
still accepts it. The distinction is carried as metadata rather than as a hard
rejection.

If the caller also needs a non-default local Ollama endpoint, pass
`ollama_base_url:` when building the payload. The normalized Codex/Ollama
payload carries that transport choice in `selection.env_overrides` as
`CODEX_OSS_BASE_URL`, so downstream CLI renderers and SDK transports can rely
on the payload alone after normalization.

## Reviewer Checklist

When reviewing model-selection changes in core, verify these invariants:

- the provider catalogs remain core-owned
- new provider/model policy enters through the registry, not a profile
- provider profiles only format arguments from resolved state
- no placeholder, blank, or invalid model silently falls through
- the visible error contract remains stable
