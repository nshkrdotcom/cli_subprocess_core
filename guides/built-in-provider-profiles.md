# Built-In Provider Profiles

`CliSubprocessCore` ships four first-party provider profiles for the common CLI
runtime lane:

- `CliSubprocessCore.ProviderProfiles.Claude`
- `CliSubprocessCore.ProviderProfiles.Codex`
- `CliSubprocessCore.ProviderProfiles.Gemini`
- `CliSubprocessCore.ProviderProfiles.Amp`

They are loaded into the default provider registry at application startup.

These remain the runtime stack's first-party common profiles. They ship inside
`cli_subprocess_core` rather than moving into separate profile packages.

## Registry Ids

| Provider | Registry id | Default command |
| --- | --- | --- |
| Claude | `:claude` | `claude` |
| Codex | `:codex` | `codex` |
| Gemini | `:gemini` | `gemini` |
| Amp | `:amp` | `amp` |

## Common Behavior

All built-in profiles own:

- command construction for the provider CLI
- JSONL stdout decoding into normalized core events
- stderr decoding into `:stderr` events
- terminal exit handling
- provider capability declaration

All provider-specific options live on the session startup keyword list and are
passed through to the selected profile.

One important distinction:

- `permission_mode`
  - common higher-layer approval/edit posture that this repo maps onto
    provider-native CLI flags
- `provider_permission_mode`
  - explicit provider-native permission choice when a caller already knows the
    exact native mode to use
- provider-native options such as Gemini `sandbox`
  - extra provider-specific flags that are not part of the shared permission
    abstraction

If you need the shipped module list directly, call
`CliSubprocessCore.first_party_profile_modules/0`.

## Claude

Command shape:

```text
claude --output-format stream-json --verbose --print ...
```

Common Claude options:

- `:prompt`
- `:command` or `:path_to_claude_code_executable`
- `:model`
- `:model_payload`
- `:max_turns`
- `:append_system_prompt`
- `:system_prompt`
- `:resume`
- `:permission_mode`
- `:provider_permission_mode`
- `:include_thinking`

The Claude profile does not own model policy.

It reads `model_payload.resolved_model` for `--model` and merges any
core-owned `model_payload.env_overrides` into the final CLI invocation. That is
what allows the same Claude profile to run either the native Anthropic backend
or an Anthropic-compatible Ollama backend without a second model-selection path
inside the profile.

## Codex

Command shape:

```text
codex exec --json ...
```

Common Codex options:

- `:prompt`
- `:command`
- `:model_payload`
- `:output_schema`
- `:permission_mode`
- `:provider_permission_mode`

The Codex profile does not own model or backend policy.

It reads the resolved payload for:

- `--model`
- `--config model_reasoning_effort=...`
- `--config model_provider="..."`
- `--config model="..."`

That is what allows the same profile to render either the normal OpenAI Codex
path or the local Codex OSS/Ollama path without inventing a second fallback or
validation layer. For one-shot exec runs it also closes stdin on start so the
upstream Codex CLI does not block on EOF after the prompt is already present on
argv.

## Gemini

Command shape:

```text
gemini --prompt ... --output-format stream-json ...
```

Common Gemini options:

- `:prompt`
- `:command`
- `:model`
- `:output_format`
- `:sandbox`
- `:extensions`
- `:permission_mode`
- `:provider_permission_mode`

Gemini is the built-in profile that currently exposes an explicit provider
`sandbox` flag on the common CLI lane. That is provider-native behavior, not a
generic `CliSubprocessCore` sandbox abstraction shared across all providers.

## Amp

Command shape:

```text
amp run --output jsonl ...
```

Common Amp options:

- `:prompt`
- `:command`
- `:model`
- `:mode`
- `:max_turns`
- `:system_prompt`
- `:permissions`
- `:mcp_config`
- `:tools`
- `:include_thinking`
- `:permission_mode`
- `:provider_permission_mode`

## How To Read These Knobs

`CliSubprocessCore` is the built-in CLI profile layer. At this layer:

- `permission_mode` means "use the shared normalized permission concept and let
  the profile map it to native CLI args"
- `provider_permission_mode` means "skip the normalized concept and specify the
  provider-native permission term directly"
- provider-specific options such as Gemini `sandbox` are separate from the
  permission mapping and only exist for the providers that actually support
  them

## Capability Hints

The built-in profiles expose capability lists that downstream consumers can use
for lane selection and feature checks.

Examples:

- Claude advertises approval, cost, resume, streaming, thinking, and tool use.
- Codex advertises reasoning, plan mode, structured output, and tool use.
- Gemini advertises sandbox and extension support.
- Amp advertises approval, MCP config, thinking, and tool use.

## Example

```elixir
{:ok, _session, info} =
  CliSubprocessCore.Session.start_session(
    provider: :amp,
    prompt: "Summarize the repository",
    model: "amp-1"
  )

info.capabilities
```

## Packaging Boundary

The built-in status in this guide is a package ownership statement:

- these four profiles ship with `cli_subprocess_core`
- future third-party profiles belong in external packages
- external profiles can still be preloaded into the default registry, but that
  preload does not make them first-party built-ins
