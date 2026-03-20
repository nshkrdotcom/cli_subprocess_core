# Provider Profile Contract

`CliSubprocessCore.ProviderProfile` defines the contract every built-in or
external provider CLI profile must implement.

## Behaviour Surface

```elixir
@callback id() :: atom()
@callback capabilities() :: [atom()]
@callback build_invocation(keyword()) ::
            {:ok, CliSubprocessCore.Command.t()} | {:error, term()}
@callback init_parser_state(keyword()) :: term()
@callback decode_stdout(binary(), term()) ::
            {[CliSubprocessCore.Event.t()], term()}
@callback decode_stderr(binary(), term()) ::
            {[CliSubprocessCore.Event.t()], term()}
@callback handle_exit(term(), term()) ::
            {[CliSubprocessCore.Event.t()], term()}
@callback transport_options(keyword()) :: keyword()
```

## Responsibilities

Each profile owns:

- the normalized provider id
- the capability list exposed to downstream consumers
- CLI command construction for that provider
- stdout parsing into normalized core events
- stderr parsing into normalized core events
- exit handling into normalized terminal events
- transport option overrides needed by the provider CLI

The foundation explicitly keeps those responsibilities out of downstream repos.

## Validation Helpers

The behaviour module provides two helper functions:

- `CliSubprocessCore.ProviderProfile.ensure_module/1`
- `CliSubprocessCore.ProviderProfile.validate_invocation/1`

`ensure_module/1` verifies that a module is loaded, declares the behaviour, and
exports the required callbacks.

`validate_invocation/1` verifies that the profile returned a valid
`CliSubprocessCore.Command` struct.

## Registry Integration

`CliSubprocessCore.ProviderRegistry` stores provider profile modules by id.

Built-in registrations are supported at application boot:

```elixir
config :cli_subprocess_core,
  built_in_profile_modules: [
    MyApp.ProviderProfiles.Example
  ]
```

Ad hoc registrations can also be added at runtime:

```elixir
:ok =
  CliSubprocessCore.ProviderRegistry.register(
    MyApp.ProviderProfiles.Example
  )
```

## Design Constraints

Provider profiles should emit only `CliSubprocessCore.Event` values containing
`CliSubprocessCore.Payload.*` structs. They should not invent competing
normalized payload families in downstream repos.

For a step-by-step implementation guide, see
`guides/custom-provider-profiles.md`.
