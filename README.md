# CliSubprocessCore

`CliSubprocessCore` is the shared foundation for the common CLI subprocess
runtime described in `/home/home/p/g/n/jido_brainstorm/nshkrdotcom/docs/20260318/cli_runtime_stack_rearchitecture/phase_1_execution_ready`.

The project root is `/home/home/p/g/n/cli_subprocess_core`.

This initial foundation owns:

- the normalized runtime event envelope in `CliSubprocessCore.Event`
- the normalized payload vocabulary in `CliSubprocessCore.Payload.*`
- the provider profile behaviour in `CliSubprocessCore.ProviderProfile`
- the provider profile registry in `CliSubprocessCore.ProviderRegistry`
- the shared support modules used by later transport and session work

The first-party provider profile modules and the higher-level session and raw
transport layers land in later prompts. This repo already includes the contract
surface those modules will plug into.

## Core Surface

- `CliSubprocessCore` exposes convenience entrypoints for built-in profile
  discovery and normalized event kind discovery.
- `CliSubprocessCore.Application` starts the task supervisor and provider
  registry.
- `CliSubprocessCore.Command` normalizes subprocess invocation data.
- `CliSubprocessCore.LineFraming` incrementally frames stdout and stderr into
  complete lines.
- `CliSubprocessCore.ProcessExit` normalizes process exit reasons.
- `CliSubprocessCore.Runtime` maintains per-session event sequencing and
  metadata.
- `CliSubprocessCore.TaskSupport` wraps the task startup and
  `Task.yield || Task.shutdown` pattern used by subprocess ownership code.

## Built-In Profile Registration

The default registry is started by `CliSubprocessCore.Application`. Built-in
profile modules can be preloaded with application configuration:

```elixir
config :cli_subprocess_core,
  built_in_profile_modules: [
    MyApp.ProviderProfiles.Example
  ]
```

No first-party profile modules are shipped in this prompt, but the registry
supports those built-in registrations now.

## Guides

The initial guides live at:

- `/home/home/p/g/n/cli_subprocess_core/guides/getting-started.md`
- `/home/home/p/g/n/cli_subprocess_core/guides/event-and-payload-model.md`
- `/home/home/p/g/n/cli_subprocess_core/guides/provider-profile-contract.md`

## Validation

The project is intended to pass:

```bash
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
mix docs
```
