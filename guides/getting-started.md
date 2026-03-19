# Getting Started

This guide lives at `/home/home/p/g/n/cli_subprocess_core/guides/getting-started.md`.

The project root is `/home/home/p/g/n/cli_subprocess_core`.

## What Exists In The Foundation

The current foundation gives downstream repos a stable starting point for:

- normalized subprocess command data with `CliSubprocessCore.Command`
- normalized runtime events with `CliSubprocessCore.Event`
- normalized payload structs with `CliSubprocessCore.Payload.*`
- provider profile validation with `CliSubprocessCore.ProviderProfile`
- provider profile lookup with `CliSubprocessCore.ProviderRegistry`
- runtime sequencing with `CliSubprocessCore.Runtime`

The raw transport and session engine modules described by the architecture
packet are intentionally not implemented in this prompt.

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

Or preload it as a built-in profile:

```elixir
config :cli_subprocess_core,
  built_in_profile_modules: [
    MyApp.ProviderProfiles.Example
  ]
```

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
