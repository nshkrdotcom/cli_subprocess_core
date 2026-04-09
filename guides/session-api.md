# Session API

`CliSubprocessCore.Session` is the normalized long-lived provider session
runtime.

It adds provider command construction, stdout/stderr decoding, normalized event
sequencing, and subscriber fanout above the shared transport substrate.

## Start A Session

```elixir
ref = make_ref()

{:ok, session, info} =
  CliSubprocessCore.Session.start_session(
    provider: :claude,
    prompt: "Explain the latest failing test",
    subscriber: {self(), ref}
  )
```

## Session Delivery

Tagged subscribers receive:

- `{session_event_tag, ref, {:event, %CliSubprocessCore.Event{}}}`

Use `CliSubprocessCore.Session.extract_event/2` instead of hard-coding the
outer mailbox shape.

## Transport Snapshot

`Session.info/1` exposes transport data through the extracted substrate:

- `info.transport.module` is `ExecutionPlane.Process.Transport`
- `info.transport.info` is `ExternalRuntimeTransport.Transport.Info`
  projected from the shared Execution Plane transport snapshot
- `info.transport.status` reflects the normalized transport status

That keeps the core session API stable while the local session-bearing lane now
runs on the Execution Plane-owned process transport seam.

## Placement

Pass `execution_surface` when the provider session should run somewhere other
than the default local subprocess:

```elixir
{:ok, session, info} =
  CliSubprocessCore.Session.start_session(
    provider: :gemini,
    prompt: "Hello from SSH",
    execution_surface: [
      surface_kind: :ssh_exec,
      transport_options: [destination: "buildbox.example"]
    ]
  )
```

## Lifecycle Calls

The core session API exposes:

- `send/2`
- `send_input/3`
- `end_input/1`
- `interrupt/1`
- `close/1`
- `subscribe/2`
- `subscribe/3`
- `unsubscribe/2`
- `info/1`

These calls delegate to the transport substrate but keep provider-facing
semantics and event normalization in the core.
