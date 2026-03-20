# Session API

`CliSubprocessCore.Session` is the common normalized runtime above the raw
transport layer. It resolves a provider profile, builds the CLI invocation,
owns parser state, and emits sequenced `CliSubprocessCore.Event` values to
subscribers.

## Start A Session

Use `start_session/1` when you want the session pid and an initial info
snapshot back together:

```elixir
{:ok, session, info} =
  CliSubprocessCore.Session.start_session(
    provider: :claude,
    prompt: "Summarize the repo",
    subscriber: {self(), make_ref()},
    metadata: %{lane: :core}
  )
```

Use `start_link/1` when you want plain OTP startup semantics.

Required startup input is either:

- `:provider` resolved through `CliSubprocessCore.ProviderRegistry`
- `:profile` with an explicit `CliSubprocessCore.ProviderProfile` module

Common session-level options:

- `:provider`
- `:profile`
- `:subscriber`
- `:metadata`
- `:registry`
- `:transport_module`
- `:session_event_tag`

All other options are passed through to the provider profile for command
construction, parser initialization, and transport overrides.

## Lifecycle API

`CliSubprocessCore.Session` exposes:

- `start_session/1`
- `start_link/1`
- `send/2`
- `send_input/3`
- `end_input/1`
- `interrupt/1`
- `close/1`
- `subscribe/2`
- `subscribe/3`
- `unsubscribe/2`
- `info/1`

`send/2` and `send_input/3` forward stdin to the underlying transport.
`end_input/1` sends EOF. `interrupt/1` sends SIGINT through the raw transport.
`close/1` stops the session process and closes the transport.

## Subscriber Mailbox Contract

Legacy subscribers receive:

```elixir
{:session_event, %CliSubprocessCore.Event{}}
```

Tagged subscribers receive:

```elixir
{:cli_subprocess_core_session, ref, {:event, %CliSubprocessCore.Event{}}}
```

You can override the outer event atom with `:session_event_tag`.

The session emits a synthetic `:run_started` event first, then provider-parsed
events in normalized runtime order.

## Info Snapshot

`info/1` returns a map shaped like:

```elixir
%{
  capabilities: [:streaming, :interrupt],
  invocation: %CliSubprocessCore.Command{},
  metadata: %{lane: :core},
  profile: CliSubprocessCore.ProviderProfiles.Claude,
  provider: :claude,
  runtime: %{
    metadata: %{lane: :core},
    profile: CliSubprocessCore.ProviderProfiles.Claude,
    provider: :claude,
    provider_session_id: nil,
    sequence: 0
  },
  session_event_tag: :cli_subprocess_core_session,
  subscribers: 1,
  transport: %{
    module: CliSubprocessCore.Transport,
    pid: #PID<0.0.0>,
    status: :connected,
    stderr: ""
  }
}
```

## Example

```elixir
ref = make_ref()

{:ok, _session, _info} =
  CliSubprocessCore.Session.start_session(
    provider: :codex,
    prompt: "Review this diff",
    subscriber: {self(), ref}
  )

receive do
  {:cli_subprocess_core_session, ^ref, {:event, event}} ->
    IO.inspect(event.kind)
end
```

The session stops itself after the underlying provider subprocess exits and the
profile has emitted any final normalized events.

For profile implementation details, see `guides/custom-provider-profiles.md`.
