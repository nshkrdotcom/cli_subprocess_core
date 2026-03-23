<p align="center">
  <img src="assets/cli_subprocess_core.svg" alt="CliSubprocessCore logo" width="240" />
</p>

# CliSubprocessCore

<p align="center">
  <a href="https://hex.pm/packages/cli_subprocess_core">
    <img src="https://img.shields.io/hexpm/v/cli_subprocess_core.svg" alt="Hex" />
  </a>
  <a href="https://hexdocs.pm/cli_subprocess_core">
    <img src="https://img.shields.io/badge/hexdocs-docs-blue.svg" alt="HexDocs" />
  </a>
  <a href="https://github.com/nshkrdotcom/cli_subprocess_core">
    <img src="https://img.shields.io/badge/github-nshkrdotcom%2Fcli__subprocess__core-24292e.svg" alt="GitHub" />
  </a>
</p>

`CliSubprocessCore` is the shared runtime foundation for first-party CLI
providers. It owns the raw subprocess transport, the normalized session/event
model above that transport, the shared non-PTY command lane, and the built-in
provider profiles that turn provider-specific JSONL streams into a stable core
vocabulary. Within the runtime stack, it is the only repo that owns `erlexec`
startup, `:exec.*`, and raw subprocess lifecycle state.

The library is designed for two consumers:

- callers that only need process ownership and mailbox delivery through
  `CliSubprocessCore.Transport`
- callers that need a provider-agnostic long-lived raw session handle through
  `CliSubprocessCore.RawSession`
- callers that need provider-aware one-shot command execution through
  `CliSubprocessCore.Command.run/1` or `run/2`
- callers that want provider resolution, command construction, parsing, event
  sequencing, and normalized payloads through `CliSubprocessCore.Session`

## Menu

- [Overview](#clisubprocesscore)
- [What The Package Owns](#what-the-package-owns)
- [Quick Start](#quick-start)
- [Built-In Profiles](#built-in-profiles)
- [Guides](#guides)
- [Project Links](#project-links)
- [Development](#development)

## What The Package Owns

- `CliSubprocessCore.Event` and `CliSubprocessCore.Payload.*` define the shared
  runtime event vocabulary.
- `CliSubprocessCore.Command` owns normalized invocations and the provider-aware
  one-shot command boundary for common non-PTY CLI flows.
- `CliSubprocessCore.ProviderProfile` and `CliSubprocessCore.ProviderRegistry`
  define and manage provider profile modules.
- `CliSubprocessCore.ProviderProfiles.*` ships first-party profiles for Claude,
  Codex, Gemini, and Amp.
- `CliSubprocessCore.Transport` and
  `CliSubprocessCore.Transport.Erlexec` own subprocess lifecycle, stdout/stderr
  dispatch, PTY startup, raw-byte versus line-oriented IO contracts,
  synchronous `run/2`, interrupt, close, force-close behavior, and transport
  metadata through `CliSubprocessCore.Transport.Info`.
- `CliSubprocessCore.RawSession` owns the provider-agnostic raw-session handle
  above the transport for long-lived subprocess families that need exact-byte
  stdin/stdout defaults, optional PTY startup, and normalized collection.
- `CliSubprocessCore.Session` adds provider-aware parsing, sequencing, and
  subscriber fan-out on top of the raw transport.
- `CliSubprocessCore.Transport` is the only public layer that exposes lazy
  startup directly. `CliSubprocessCore.RawSession` and
  `CliSubprocessCore.Session` wait for subprocess startup to either succeed or
  fail before returning.
- `CliSubprocessCore.Runtime`, `CliSubprocessCore.LineFraming`,
  `CliSubprocessCore.ProcessExit`, and `CliSubprocessCore.TaskSupport` support
  the transport and session layers.

## Quick Start

Add the dependency and start the application normally:

```elixir
def deps do
  [
    {:cli_subprocess_core, "~> 0.1.0"}
  ]
end
```

For local workspace development, replace the published requirement with a
sibling `path:` override.

Use the raw transport when you only need subprocess IO:

```elixir
ref = make_ref()

{:ok, transport} =
  CliSubprocessCore.Transport.start(
    command: CliSubprocessCore.Command.new("sh", ["-c", "cat"]),
    subscriber: {self(), ref}
  )

:ok = CliSubprocessCore.Transport.send(transport, "hello")
:ok = CliSubprocessCore.Transport.end_input(transport)

receive do
  {:cli_subprocess_core, ^ref, {:message, "hello"}} -> :ok
end
```

Use the raw session handle when you need long-lived exact-byte ownership:

```elixir
{:ok, session} =
  CliSubprocessCore.RawSession.start("sh", ["-c", "cat"], stdin?: true)

:ok = CliSubprocessCore.RawSession.send_input(session, "alpha")
:ok = CliSubprocessCore.RawSession.close_input(session)

{:ok, result} = CliSubprocessCore.RawSession.collect(session, 5_000)
IO.inspect({result.stdout, result.exit.code})
```

Use the command lane when you need one-shot non-PTY execution:

```elixir
invocation =
  CliSubprocessCore.Command.new("sh", ["-c", "printf \"alpha\" && printf \"beta\" >&2"])

{:ok, result} =
  CliSubprocessCore.Command.run(invocation,
    stderr: :stdout,
    timeout: 5_000
  )

IO.inspect({result.output, result.exit.code})
```

Use the session layer when you want provider command building and normalized
events:

```elixir
ref = make_ref()

{:ok, _session, info} =
  CliSubprocessCore.Session.start_session(
    provider: :claude,
    prompt: "Summarize this repository",
    subscriber: {self(), ref},
    metadata: %{lane: :core}
  )

IO.inspect(info.capabilities)

receive do
  {:cli_subprocess_core_session, ^ref, {:event, event}} ->
    IO.inspect({event.sequence, event.kind})
end
```

## Built-In Profiles

Phase 3 finalizes the publication story for the common provider-profile layer:

- the first-party common profiles for Claude, Codex, Gemini, and Amp stay
  built into `cli_subprocess_core`
- third-party common profiles belong in external packages that implement
  `CliSubprocessCore.ProviderProfile`
- external profiles register explicitly at runtime or are preloaded through app
  config; that preload does not make them first-party built-ins

The shipped first-party modules are available through
`CliSubprocessCore.first_party_profile_modules/0`.

The default registry starts with these ids:

- `:claude`
- `:codex`
- `:gemini`
- `:amp`

You can preload additional external profile modules through application config:

```elixir
config :cli_subprocess_core,
  built_in_profile_modules: [MyApp.ProviderProfiles.Example]
```

That config only controls what the default registry boots with. It does not
change first-party package ownership.

Ad hoc external profiles can also be registered at runtime with
`CliSubprocessCore.ProviderRegistry.register/2`.

## Guides

- `guides/getting-started.md`
- `guides/event-and-payload-model.md`
- `guides/provider-profile-contract.md`
- `guides/custom-provider-profiles.md`
- `guides/built-in-provider-profiles.md`
- `guides/command-api.md`
- `guides/raw-transport.md`
- `guides/session-api.md`
- `guides/testing-and-conformance.md`
- `guides/shutdown-and-timeouts.md`

## Project Links

- Hex: `https://hex.pm/packages/cli_subprocess_core`
- HexDocs: `https://hexdocs.pm/cli_subprocess_core`
- GitHub: `https://github.com/nshkrdotcom/cli_subprocess_core`
- Changelog: `CHANGELOG.md`
- License: `LICENSE`

## Development

The repo-local quality gate is:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix docs
mix hex.build
```
