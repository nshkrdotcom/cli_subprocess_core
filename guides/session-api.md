# Session API

`CliSubprocessCore.Session` is the common normalized runtime above the raw
transport layer. It resolves a provider profile, builds the CLI invocation,
owns parser state, and emits sequenced `CliSubprocessCore.Event` values to
subscribers. Session startup waits for the underlying subprocess transport to
either connect or fail before `start_session/1` returns, so the synthetic
`:run_started` event only appears after spawn success.

## Start A Session

Use `start_session/1` when you want the session pid and an initial info
snapshot back together:

```elixir
ref = make_ref()

{:ok, session, info} =
  CliSubprocessCore.Session.start_session(
    provider: :claude,
    prompt: "Summarize the repo",
    subscriber: {self(), ref},
    metadata: %{lane: :core}
  )
```

`start_session/1` does not keep the caller linked to the session after startup.
Use `start_link/1` when you want plain OTP linked-process semantics. Use
`start_link_session/1` when you want the same initial info snapshot as
`start_session/1` while also keeping the session linked to the caller. Both
entrypoints still wait for the same startup handshake before returning.

Required startup input is either:

- `:provider` resolved through `CliSubprocessCore.ProviderRegistry`
- `:profile` with an explicit `CliSubprocessCore.ProviderProfile` module

Common session-level options:

- `:provider`
- `:profile`
- `:subscriber`
- `:metadata`
- `:registry`
- `:session_event_tag` for low-level adapter-controlled tagged delivery; higher-level
  callers should keep that raw tag below their projected public event surface
- `:surface_kind`
- `:transport_options`
- `:target_id`
- `:lease_ref`
- `:surface_ref`
- `:boundary_class`
- `:observability`

All other options are passed through to the provider profile for command
construction, parser initialization, and profile-owned transport defaults. The
core merges those defaults with the public `:transport_options` lane and then
resolves the concrete adapter internally from `:surface_kind`. If the selected
transport is configured for lazy startup, the session still waits for that
startup to finish before returning. The landed surfaces today are
`:local_subprocess`, `:ssh_exec`, and `:guest_bridge`. Legacy
backend-selection overrides are rejected.

## Lifecycle API

`CliSubprocessCore.Session` exposes:

- `start_session/1`
- `start_link_session/1`
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
`end_input/1` sends the correct EOF form for the active transport contract:
`:eof` for pipe-backed stdin and `Ctrl-D` for PTY-backed stdin. `interrupt/1`
sends SIGINT through the raw transport.
`close/1` stops the session process and closes the transport.

## Subscriber Mailbox Contract

Legacy subscribers receive:

```elixir
{:session_event, %CliSubprocessCore.Event{}}
```

Tagged subscribers receive this shape by default:

```elixir
{:cli_subprocess_core_session, ref, {:event, %CliSubprocessCore.Event{}}}
```

If an adapter overrides `:session_event_tag`, tagged subscribers receive the
same payload with a different outer event atom:

```elixir
{:sdk_runtime_session, ref, {:event, %CliSubprocessCore.Event{}}}
```

You can override the outer event atom with `:session_event_tag`, but direct
adapters should consume tagged delivery through
`CliSubprocessCore.Session.extract_event/2` instead of matching on a specific
default atom:

```elixir
receive do
  message ->
    case CliSubprocessCore.Session.extract_event(message, ref) do
      {:ok, event} -> IO.inspect(event.kind)
      :error -> :ignore
    end
end
```

The session emits a synthetic `:run_started` event first, then provider-parsed
events in normalized runtime order.

## Info Snapshot

With the default tagged delivery, `info/1` returns a map shaped like:

```elixir
%{
  capabilities: [:streaming, :interrupt],
  delivery: %CliSubprocessCore.Session.Delivery{
    legacy_message: :session_event,
    tagged_event_tag: :cli_subprocess_core_session,
    tagged_payload: :event
  },
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
    info: %CliSubprocessCore.Transport.Info{},
    status: :connected,
    stderr: "",
    subprocess_pid: #PID<0.0.1>,
    os_pid: 12_345,
    stdout_mode: :line,
    stdin_mode: :line,
    pty?: false,
    interrupt_mode: :signal
  }
}
```

If a direct adapter overrides `:session_event_tag`, the delivery fields change
accordingly:

```elixir
%{
  delivery: %CliSubprocessCore.Session.Delivery{
    legacy_message: :session_event,
    tagged_event_tag: :sdk_runtime_session,
    tagged_payload: :event
  },
  session_event_tag: :sdk_runtime_session
}
```

The session snapshot surfaces the full `%CliSubprocessCore.Transport.Info{}`
under `transport.info` plus the most commonly consumed subprocess metadata as
top-level transport map fields.

`transport.info` also carries generic execution-surface metadata such as
`surface_kind`, `target_id`, `lease_ref`, `surface_ref`, `boundary_class`, and
`observability`.

`session_event_tag` remains in the info map as a direct-adapter compatibility
alias. `delivery.tagged_event_tag` is the explicit mailbox-delivery contract.
Higher-level wrappers should set their own tag or relay into their own event
envelope rather than requiring callers to know a default core tag.

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
  message ->
    case CliSubprocessCore.Session.extract_event(message, ref) do
      {:ok, event} -> IO.inspect(event.kind)
      :error -> :ignore
    end
end
```

The session stops itself after the underlying provider subprocess exits and the
profile has emitted any final normalized events.

For profile implementation details, see `guides/custom-provider-profiles.md`.
