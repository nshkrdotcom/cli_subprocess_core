# Getting Started

This guide walks through the core modules you need first, when to use the raw
transport versus the session layer, and how to wire in a custom provider
profile.

## What Exists In The Foundation

The current foundation gives downstream repos a stable starting point for:

- normalized subprocess command data with `CliSubprocessCore.Command`
- provider-aware one-shot execution with `CliSubprocessCore.Command.run/1,2`
- normalized runtime events with `CliSubprocessCore.Event`
- normalized payload structs with `CliSubprocessCore.Payload.*`
- provider profile validation with `CliSubprocessCore.ProviderProfile`
- provider profile lookup with `CliSubprocessCore.ProviderRegistry`
- built-in first-party provider profiles for Claude, Codex, Gemini, and Amp
- runtime sequencing with `CliSubprocessCore.Runtime`
- session-oriented provider runtime ownership with `CliSubprocessCore.Session`
- raw subprocess ownership with `CliSubprocessCore.Transport`

## Define A Provider Profile

Start with a module that implements `CliSubprocessCore.ProviderProfile`:

```elixir
defmodule MyApp.ProviderProfiles.Example do
  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.{Command, Event, Payload, ProcessExit}

  @impl true
  def id, do: :example

  @impl true
  def capabilities, do: [:streaming, :interrupt]

  @impl true
  def build_invocation(_opts) do
    {:ok, Command.new("example-cli", ["run"])}
  end

  @impl true
  def init_parser_state(_opts), do: %{}

  @impl true
  def decode_stdout(data, state) do
    payload = Payload.AssistantDelta.new(content: data)
    event = Event.new(:assistant_delta, provider: id(), payload: payload)
    {[event], state}
  end

  @impl true
  def decode_stderr(data, state) do
    payload = Payload.Stderr.new(content: data)
    event = Event.new(:stderr, provider: id(), payload: payload)
    {[event], state}
  end

  @impl true
  def handle_exit(reason, state) do
    exit = ProcessExit.from_reason(reason)
    payload = Payload.Result.new(status: exit.status, stop_reason: exit.reason)
    event = Event.new(:result, provider: id(), payload: payload)
    {[event], state}
  end

  @impl true
  def transport_options(_opts), do: []
end
```

## Register The Profile

Register a profile module in the default registry:

```elixir
:ok = CliSubprocessCore.ProviderRegistry.register(MyApp.ProviderProfiles.Example)
{:ok, MyApp.ProviderProfiles.Example} =
  CliSubprocessCore.ProviderRegistry.fetch(:example)
```

Or preload the external profile into the default registry at boot:

```elixir
config :cli_subprocess_core,
  built_in_profile_modules: [
    MyApp.ProviderProfiles.Example
  ]
```

That preload hook affects the boot registry list only. It does not make the
external profile a first-party built-in shipped by `cli_subprocess_core`.

## Emit Sequenced Events

`CliSubprocessCore.Runtime` centralizes provider id, provider session id, and
event sequencing:

```elixir
runtime =
  CliSubprocessCore.Runtime.new(
    provider: :example,
    profile: MyApp.ProviderProfiles.Example,
    provider_session_id: "provider-session-1",
    metadata: %{lane: :core}
  )

payload = CliSubprocessCore.Payload.AssistantDelta.new(content: "hello")

{event, runtime} =
  CliSubprocessCore.Runtime.next_event(runtime, :assistant_delta, payload)
```

The resulting `event` includes:

- the normalized kind
- the provider id
- the next sequence number
- the provider session id
- the merged runtime metadata

## Frame Incremental Output

`CliSubprocessCore.LineFraming` lets transport code accumulate partial stdout
and stderr chunks without losing line boundaries:

```elixir
state = CliSubprocessCore.LineFraming.new()
{lines, state} = CliSubprocessCore.LineFraming.push(state, "alpha\nbeta")
{tail, state} = CliSubprocessCore.LineFraming.flush(state)
```

`lines` contains complete lines and `tail` contains the final buffered fragment
once the stream ends.

## Start A Raw Transport

Use `CliSubprocessCore.Transport` when you need raw process ownership without
provider-specific parsing:

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

See `guides/raw-transport.md` for the transport contract and
`guides/shutdown-and-timeouts.md` for shutdown and timeout behavior.

## Run A One-Shot Command

Use the command lane when you need exact stdin/stdout/stderr capture without a
long-lived session:

```elixir
invocation =
  CliSubprocessCore.Command.new("sh", ["-c", "printf \"alpha\" && printf \"beta\" >&2"])

{:ok, result} =
  CliSubprocessCore.Command.run(invocation,
    stderr: :stdout,
    timeout: 5_000
  )
```

Or let the core resolve a provider profile and build the invocation:

```elixir
{:ok, result} =
  CliSubprocessCore.Command.run(
    provider: :claude,
    prompt: "Summarize the repo"
  )
```

See `guides/command-api.md` for the provider-aware boundary and
`guides/raw-transport.md` for the lower transport-owned execution contract.

## Start A Session

Use the session layer when you want provider command construction, parsing, and
normalized event emission handled by the core:

```elixir
ref = make_ref()

{:ok, _session, _info} =
  CliSubprocessCore.Session.start_session(
    provider: :claude,
    prompt: "Summarize the repo",
    subscriber: {self(), ref}
  )

receive do
  {:cli_subprocess_core_session, ^ref, {:event, event}} ->
    IO.inspect({event.sequence, event.kind})
end
```

See `guides/session-api.md` for the session contract,
`guides/command-api.md` for the one-shot command lane,
`guides/built-in-provider-profiles.md` for the first-party profile catalog, and
`guides/custom-provider-profiles.md` for extension guidance.
