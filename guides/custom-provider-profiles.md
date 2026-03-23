# Custom Provider Profiles

`CliSubprocessCore.ProviderProfile` is the extension point for providers that
are not shipped with the package. A custom profile owns command construction,
parser state, stdout/stderr decoding, terminal exit handling, and any
transport overrides needed by that CLI.

## When To Add A Profile

Add a custom profile when:

- the provider CLI already exists and should run through the common runtime
- you need normalized `CliSubprocessCore.Event` values instead of provider-only
  payloads
- downstream code should not duplicate command-building or JSONL parsing logic

If you only need raw subprocess ownership, use `CliSubprocessCore.Transport`
directly and skip the profile layer.

Phase 2B freezes the packaging rule for this layer:

- first-party common profiles stay built into `cli_subprocess_core` through the
  initial published stack cut
- third-party/common custom profiles belong in external packages that implement
  `CliSubprocessCore.ProviderProfile`
- those external packages register explicitly at runtime or preload
  intentionally at registry boot

## Behaviour Surface

Every profile implements:

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

The contract is documented in more detail in
`guides/provider-profile-contract.md`.

## Minimal Example

```elixir
defmodule MyApp.ProviderProfiles.Example do
  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.{Command, Event, Payload, ProcessExit}

  @impl true
  def id, do: :example

  @impl true
  def capabilities, do: [:interrupt, :streaming]

  @impl true
  def build_invocation(opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    {:ok, Command.new("example-cli", ["run", "--jsonl", prompt])}
  end

  @impl true
  def init_parser_state(_opts) do
    %{provider_session_id: nil}
  end

  @impl true
  def decode_stdout(line, state) do
    payload = Payload.AssistantDelta.new(content: line)

    event =
      Event.new(:assistant_delta,
        provider: id(),
        payload: payload,
        provider_session_id: state.provider_session_id
      )

    {[event], state}
  end

  @impl true
  def decode_stderr(chunk, state) do
    payload = Payload.Stderr.new(content: chunk)
    event = Event.new(:stderr, provider: id(), payload: payload)
    {[event], state}
  end

  @impl true
  def handle_exit(reason, state) do
    exit = ProcessExit.from_reason(reason)

    payload =
      if ProcessExit.successful?(exit) do
        Payload.Result.new(status: :completed, stop_reason: exit.reason, output: %{code: exit.code})
      else
        Payload.Error.new(message: "CLI exited with code #{exit.code}", code: Integer.to_string(exit.code))
      end

    kind = if ProcessExit.successful?(exit), do: :result, else: :error
    event = Event.new(kind, provider: id(), payload: payload)

    {[event], state}
  end

  @impl true
  def transport_options(_opts), do: []
end
```

## Command Construction

`build_invocation/1` should return a fully validated
`CliSubprocessCore.Command`:

- resolve CLI-specific flags and defaults here
- keep session-level reserved keys out of the profile logic
- return `{:error, term()}` for missing required inputs instead of raising
- put provider-specific environment and cwd handling into the command struct

Use `CliSubprocessCore.ProviderProfile.validate_invocation/1` when testing the
result.

## Parser State

`init_parser_state/1` should return exactly the state your parser needs:

- provider session id or conversation id
- partial result tracking
- flags such as `result_emitted?`
- any CLI-specific decode context

The state returned from `decode_stdout/2`, `decode_stderr/2`, and
`handle_exit/2` is fed back into subsequent callbacks by
`CliSubprocessCore.Session`.

## Emitting Normalized Events

Profiles should emit `CliSubprocessCore.Event` structs containing
`CliSubprocessCore.Payload.*` structs. That keeps the shared runtime vocabulary
stable across SDKs and higher-level orchestration layers.

Common patterns:

- map streamed text to `Payload.AssistantDelta`
- map completed messages to `Payload.AssistantMessage`
- map stderr chunks to `Payload.Stderr`
- map terminal success to `Payload.Result`
- map non-zero exits and parse failures to `Payload.Error`
- emit `provider_session_id` whenever the CLI exposes one

The session layer will assign the final `id`, `sequence`, timestamp, provider,
and merged metadata when it normalizes and dispatches each event.

## Transport Overrides

`transport_options/1` is the profile hook for raw transport tuning. Use it for:

- larger stdout buffers when the provider emits large JSONL lines
- stderr callbacks used by CLI-specific diagnostics
- custom headless timeouts
- lazy startup or other transport-level behavior

Do not put `:command`, `:args`, `:cwd`, `:env`, `:subscriber`, or `:event_tag`
in the returned keyword list. `CliSubprocessCore.Session` owns those values.

## Registration

Register the profile explicitly:

```elixir
:ok = CliSubprocessCore.ProviderRegistry.register(MyApp.ProviderProfiles.Example)
```

Or add it to the app config so the default registry boots with it:

```elixir
config :cli_subprocess_core,
  built_in_profile_modules: [MyApp.ProviderProfiles.Example]
```

That preload hook only affects the local registry boot list. It does not turn
your external package into a first-party built-in profile.

Then start a session with either `provider: :example` or
`profile: MyApp.ProviderProfiles.Example`.

## Recommended Test Matrix

Every custom profile should cover:

- command-building unit tests
- parser tests for stdout fixture lines
- parser tests for stderr chunks
- exit handling for success, interrupt, and non-zero exits
- session integration tests using a mock CLI script

See `guides/testing-and-conformance.md` for the full conformance checklist.
