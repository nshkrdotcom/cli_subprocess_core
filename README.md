# CliSubprocessCore

`CliSubprocessCore` is the shared foundation for the common CLI subprocess
runtime described in `/home/home/p/g/n/jido_brainstorm/nshkrdotcom/docs/20260318/cli_runtime_stack_rearchitecture/phase_1_execution_ready`.

The project root is `/home/home/p/g/n/cli_subprocess_core`.

This initial foundation owns:

- the normalized runtime event envelope in `CliSubprocessCore.Event`
- the normalized payload vocabulary in `CliSubprocessCore.Payload.*`
- the provider profile behaviour in `CliSubprocessCore.ProviderProfile`
- the provider profile registry in `CliSubprocessCore.ProviderRegistry`
- the built-in first-party provider profiles for Claude, Codex, Gemini, and Amp
- the common CLI session engine in `CliSubprocessCore.Session`
- the raw subprocess transport contract and erlexec-backed implementation
- the shared support modules used by the transport and session work

## Core Surface

- `CliSubprocessCore` exposes convenience entrypoints for built-in profile
  discovery and normalized event kind discovery.
- `CliSubprocessCore.Application` starts the task supervisor and provider
  registry.
- `CliSubprocessCore.Command` normalizes subprocess invocation data.
- `CliSubprocessCore.LineFraming` incrementally frames stdout and stderr into
  complete lines.
- `CliSubprocessCore.ProcessExit` normalizes process exit reasons.
- `CliSubprocessCore.ProviderProfiles.*` implements the built-in first-party
  CLI profiles.
- `CliSubprocessCore.Runtime` maintains per-session event sequencing and
  metadata.
- `CliSubprocessCore.Session` owns provider resolution, invocation building,
  parser state, subscription, and normalized event emission.
- `CliSubprocessCore.Session.Options` validates session startup options.
- `CliSubprocessCore.TaskSupport` wraps the task startup and
  `Task.yield || Task.shutdown` pattern used by subprocess ownership code.
- `CliSubprocessCore.Transport` exposes the raw transport behaviour and default
  facade.
- `CliSubprocessCore.Transport.Erlexec` implements subprocess lifecycle,
  stderr, interrupt, and force-close handling.
- `CliSubprocessCore.Transport.Options` validates transport startup options.
- `CliSubprocessCore.Transport.Error` provides structured transport failures.

## Built-In Profile Registration

The default registry is started by `CliSubprocessCore.Application` and includes
the first-party profile modules automatically. Extra built-in profile modules
can be appended with application configuration:

```elixir
config :cli_subprocess_core,
  built_in_profile_modules: [
    MyApp.ProviderProfiles.Example
  ]
```

The built-in ids are:

- `:claude`
- `:codex`
- `:gemini`
- `:amp`

## Guides

The initial guides live at:

- `/home/home/p/g/n/cli_subprocess_core/guides/getting-started.md`
- `/home/home/p/g/n/cli_subprocess_core/guides/event-and-payload-model.md`
- `/home/home/p/g/n/cli_subprocess_core/guides/provider-profile-contract.md`
- `/home/home/p/g/n/cli_subprocess_core/guides/built-in-provider-profiles.md`
- `/home/home/p/g/n/cli_subprocess_core/guides/raw-transport.md`
- `/home/home/p/g/n/cli_subprocess_core/guides/session-api.md`
- `/home/home/p/g/n/cli_subprocess_core/guides/shutdown-and-timeouts.md`

## Validation

The project is intended to pass:

```bash
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
mix docs
```
