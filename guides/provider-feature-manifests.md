# Provider Feature Manifests

`CliSubprocessCore.ProviderFeatures` is the public, canonical metadata layer for
the built-in provider profiles.

It exists so higher-level adapter layers can discover provider-native
terminology and partial common-surface support without reimplementing profile
knowledge in separate lookup tables.

## What It Owns

- provider-native permission mode metadata
- rendered CLI args for those permission modes
- partial feature manifests for built-in providers

Today the partial-feature manifest covers Ollama-backed model routing.

## Permission Metadata

Use `permission_mode!/2` or `permission_args/2` when a caller needs to present
or render the provider-native form of a normalized approval choice.

```elixir
iex> CliSubprocessCore.ProviderFeatures.permission_mode!(:codex, :yolo)
%{
  native_mode: :yolo,
  cli_args: ["--dangerously-bypass-approvals-and-sandbox"],
  cli_excerpt: "--dangerously-bypass-approvals-and-sandbox",
  label: "yolo"
}

iex> CliSubprocessCore.ProviderFeatures.permission_args(:amp, :dangerously_allow_all)
["--dangerously-allow-all"]
```

This keeps provider profiles authoritative for the real CLI contract while
still giving adapter layers a stable public lookup surface.

## Partial Features

Use `partial_feature!/2` when you need to know whether a built-in provider
supports a feature that is shared by some, but not all, providers.

```elixir
iex> CliSubprocessCore.ProviderFeatures.partial_feature!(:claude, :ollama)
%{
  supported?: true,
  activation: %{provider_backend: :ollama},
  model_strategy: :canonical_or_direct_external,
  notes: [...]
}
```

Codex's manifest also carries compatibility metadata for the shared Ollama
route:

```elixir
iex> CliSubprocessCore.ProviderFeatures.partial_feature!(:codex, :ollama)
%{
  supported?: true,
  activation: %{provider_backend: :oss, oss_provider: "ollama"},
  model_strategy: :direct_external,
  compatibility: %{
    acceptance: :runtime_validated_external_model,
    default_model: "gpt-oss:20b",
    validated_models: ["gpt-oss:20b"]
  },
  notes: [...]
}
```

Current built-in `:ollama` support:

- Claude: supported through `provider_backend: :ollama`
- Codex: supported through `provider_backend: :oss, oss_provider: "ollama"`
- Gemini: unsupported on the common CLI surface
- Amp: unsupported on the common CLI surface

For Codex, the compatibility manifest describes the validated default and the
acceptance rule separately:

- acceptance: any Ollama model that passes runtime validation
- validated default: `gpt-oss:20b`
- non-default models: allowed, but may run with upstream fallback metadata

## Design Rule

`CliSubprocessCore.ProviderFeatures` should only describe built-in provider
profile behavior that the core itself owns.

It should not become a generic SDK catalog or an adapter-specific policy layer.
Higher-level packages such as ASM may wrap this metadata to describe their own
common surfaces, but the source of truth for built-in CLI behavior stays here.
