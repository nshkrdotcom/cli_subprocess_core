# Built-In Provider Profiles

This guide lives at `/home/home/p/g/n/cli_subprocess_core/guides/built-in-provider-profiles.md`.

`CliSubprocessCore` ships four first-party provider profiles for the common CLI
runtime lane:

- `CliSubprocessCore.ProviderProfiles.Claude`
- `CliSubprocessCore.ProviderProfiles.Codex`
- `CliSubprocessCore.ProviderProfiles.Gemini`
- `CliSubprocessCore.ProviderProfiles.Amp`

They are loaded into the default provider registry at application startup.

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

## Claude

Command shape:

```text
claude --output-format stream-json --verbose --print ...
```

Common Claude options:

- `:prompt`
- `:command` or `:path_to_claude_code_executable`
- `:model`
- `:max_turns`
- `:append_system_prompt`
- `:system_prompt`
- `:resume`
- `:permission_mode`
- `:provider_permission_mode`
- `:include_thinking`

## Codex

Command shape:

```text
codex exec --json ...
```

Common Codex options:

- `:prompt`
- `:command`
- `:model`
- `:reasoning_effort`
- `:output_schema`
- `:permission_mode`
- `:provider_permission_mode`

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
