# Built-In Provider Profiles

`CliSubprocessCore` ships five first-party provider profiles for the common CLI
runtime lane:

- `CliSubprocessCore.ProviderProfiles.Claude`
- `CliSubprocessCore.ProviderProfiles.Codex`
- `CliSubprocessCore.ProviderProfiles.Cursor`
- `CliSubprocessCore.ProviderProfiles.Amp`
- `CliSubprocessCore.ProviderProfiles.Antigravity`

They are loaded into the default provider registry at application startup.

These remain the runtime stack's first-party common profiles. They ship inside
`cli_subprocess_core` rather than moving into separate profile packages.

## Registry Ids

| Provider | Registry id | Default command |
| --- | --- | --- |
| Claude | `:claude` | `claude` |
| Codex | `:codex` | `codex` |
| Cursor | `:cursor` | `agent` |
| Amp | `:amp` | `amp` |
| Antigravity | `:antigravity` | `agy` |

## Common Behavior

All built-in profiles own:

- command construction for the provider CLI
- stdout decoding into normalized core events, including JSONL providers and
  plain-text providers such as Antigravity
- stderr decoding into `:stderr` events
- terminal exit handling
- provider capability declaration

All provider-specific options live on the session startup keyword list and are
passed through to the selected profile.

When `:governed_authority` is present, built-in profiles use only the
authority-materialized command, cwd, env, config root, auth root, base URL,
target refs, and `clear_env?: true` posture. Provider CLI env discovery, local
`PATH`, npx fallback, known home locations, and version-manager env remain
standalone behavior only.

One important distinction:

- `permission_mode`
  - common higher-layer approval/edit posture that this repo maps onto
    provider-native CLI flags
- `provider_permission_mode`
  - explicit provider-native permission choice when a caller already knows the
    exact native mode to use
- provider-native options such as Antigravity `sandbox`
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

The shared model registry currently exposes `gpt-5.6-sol` as the live default,
plus `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`, `gpt-5.4`,
`gpt-5.4-mini`, and the ChatGPT Pro preview `gpt-5.3-codex-spark`. The profile
consumes that resolved selection; it does not add aliases or preserve retired
model IDs.

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

## Cursor

Command shape:

```text
agent -p --trust --output-format stream-json --stream-partial-output ... <prompt>
```

The prompt is positional at the end of argv. Cursor does not use a `--prompt`
flag in this profile.

Common Cursor options:

- `:prompt`
- `:command` or `:cli_path`
- `:cwd` (also emits `--workspace <cwd>`)
- `:model`
- `:model_payload`
- `:resume`
- `:continue`
- `:mode`
- `:sandbox`
- `:approve_mcps`
- `:worktree`
- `:worktree_base`
- `:skip_worktree_setup`
- `:plugin_dirs`
- `:headers`
- `:permission_mode`
- `:provider_permission_mode`

Cursor reads `model_payload.resolved_model` before falling back to `:model`.
When `:cwd` is supplied, the profile uses it as the process working directory
and renders `--workspace <cwd>`.

Governed Cursor launches use the shared `GovernedAuthority` contract. The
authority owns command, cwd, env, and clear-env state. Cursor `config_root` and
`auth_root` are metadata only at this layer; an authority materializer must put
any required Cursor paths or `CURSOR_API_KEY` values into `authority.env`.

Cursor `system/init` events are preserved as `Payload.Raw` with parser metadata.
There is no separate `Payload.System` type in the core event model.

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
- `:permissions`
- `:mcp_config`
- `:tools`
- `:include_thinking`
- `:permission_mode`
- `:provider_permission_mode`

## Antigravity

Command shape:

```text
agy --print <prompt> ...
```

`agy --print` emits plain text on stdout, not JSONL. The Antigravity profile
maps each non-empty stdout line to an `:assistant_delta` event and uses the
shared stderr and exit handling. It also closes stdin on start because the
prompt is already fully present in argv.

Common Antigravity options:

- `:prompt`
- `:command` or `:cli_path`
- `:cwd`
- `:model`
- `:model_payload`
- `:sandbox`
- `:dangerously_skip_permissions`
- `:conversation`
- `:continue`
- `:add_dirs`
- `:print_timeout`
- `:log_file`
- `:permission_mode`
- `:provider_permission_mode`

`--add-dir` is repeatable and is never comma-delimited. `permission_mode:
:bypass` renders `--dangerously-skip-permissions` unless that flag was already
provided explicitly.

## How To Read These Knobs

`CliSubprocessCore` is the built-in CLI profile layer. At this layer:

- `permission_mode` means "use the shared normalized permission concept and let
  the profile map it to native CLI args"
- `provider_permission_mode` means "skip the normalized concept and specify the
  provider-native permission term directly"
- provider-specific options such as Antigravity `sandbox` are separate from the
  permission mapping and only exist for the providers that actually support
  them

## Capability Hints

The built-in profiles expose capability lists that downstream consumers can use
for lane selection and feature checks.

Examples:

- Claude advertises approval, cost, resume, streaming, thinking, and tool use.
- Codex advertises reasoning, plan mode, structured output, and tool use.
- Cursor advertises interrupt, MCP, plan, resume, sandbox, streaming, and tool use.
- Amp advertises approval, MCP config, thinking, and tool use.
- Antigravity advertises sandbox, streaming, directory mapping, and
  continuation on the common CLI lane.

The coarse `:tools` profile capability means the profile can normalize observed
provider tool events. It is not a common host-tool admission signal. Use
`CliSubprocessCore.ProviderFeatures.tool_capabilities!/1` for the decomposed
tool contract:

- `:tool_events` and `:tool_results` are normalized observation support.
- `:host_tools` is currently `false` for every built-in profile.
- provider tool allowlists, denylists, MCP servers, built-ins, and no-tool modes
  are `:unknown` at the common core contract until provider SDK evidence proves
  a narrower native behavior.

Provider SDKs own any provider-specific tool rendering or settings. Core
profiles must not turn Claude hooks/MCP, Codex app-server payloads, or Amp tool
configuration into shared semantics.

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

- these five profiles ship with `cli_subprocess_core`
- future third-party profiles belong in external packages
- external profiles can still be preloaded into the default registry, but that
  preload does not make them first-party built-ins
