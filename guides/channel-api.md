# Channel API

`CliSubprocessCore.Channel` is the framed-IO layer above `CliSubprocessCore.RawSession`.
Use it when you need a long-lived subprocess handle with stable mailbox
delivery, but you do not want provider-aware parsing from `CliSubprocessCore.Session`.

## When To Use A Channel

Use `Channel` when you need:

- long-lived stdin/stdout/stderr ownership
- stable tagged mailbox delivery without carrying a raw transport ref around
- the same local-versus-SSH execution surface used by the lower transport APIs

If you only need one-shot execution, use `CliSubprocessCore.Command.run/1,2` or
`ExecutionPlane.Process.Transport.run/2`. If you want provider parsing and
normalized `CliSubprocessCore.Event` values, use `CliSubprocessCore.Session`.

## Start A Channel

```elixir
ref = make_ref()

{:ok, channel, info} =
  CliSubprocessCore.Channel.start_channel(
    command: "sh",
    args: ["-c", "cat"],
    subscriber: {self(), ref},
    stdout_mode: :raw,
    stdin_mode: :raw
  )

IO.inspect(info.delivery)

:ok = CliSubprocessCore.Channel.send_input(channel, "alpha")
:ok = CliSubprocessCore.Channel.close_input(channel)

receive do
  message ->
    case CliSubprocessCore.Channel.extract_event(message, ref) do
      {:ok, {:data, chunk}} -> IO.inspect(chunk)
      {:ok, {:exit, exit}} -> IO.inspect(exit.code)
      :error -> :ignore
    end
end
```

`start_channel/1` returns the pid plus the initial info snapshot.
`start_link_channel/1` returns the same snapshot while keeping the channel
linked to the caller.

## Mailbox Contract

Legacy subscribers receive:

```elixir
{:channel_message, line}
{:channel_data, chunk}
{:channel_stderr, chunk}
{:channel_exit, %ExternalRuntimeTransport.ProcessExit{}}
{:channel_error, reason}
```

Tagged subscribers receive:

```elixir
{:cli_subprocess_core_channel, ref, {:message, line}}
{:cli_subprocess_core_channel, ref, {:data, chunk}}
{:cli_subprocess_core_channel, ref, {:stderr, chunk}}
{:cli_subprocess_core_channel, ref, {:exit, %ExternalRuntimeTransport.ProcessExit{}}}
{:cli_subprocess_core_channel, ref, {:error, reason}}
```

Use `CliSubprocessCore.Channel.extract_event/2` instead of matching on the
outer event atom directly.

## Delivery And Metadata

`CliSubprocessCore.Channel.info/1` returns:

- `delivery` metadata for the effective mailbox contract
- the normalized invocation
- subscriber count
- the underlying raw-session info
- the transport snapshot, including `surface_kind`, stderr tail, and adapter metadata

`CliSubprocessCore.Channel.delivery_info/1` is the shortest path to the stable
tagged-delivery contract.

## SSH Surfaces

Channels use the same generic execution-surface options as the transport layer.
For an SSH execution surface:

```elixir
{:ok, channel, _info} =
  CliSubprocessCore.Channel.start_channel(
    command: "sh",
    args: ["-c", "cat"],
    subscriber: {self(), make_ref()},
    stdout_mode: :raw,
    stdin_mode: :raw,
    execution_surface: [
      surface_kind: :ssh_exec,
      transport_options: [
        destination: "channel.test.example",
        ssh_user: "deploy",
        port: 22
      ]
    ]
  )
```

The core still resolves the SSH adapter internally. Callers stay on one
canonical `execution_surface`.
