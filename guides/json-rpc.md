# JSON-RPC

`CliSubprocessCore.JSONRPC` is the public JSON-RPC helper built on
`CliSubprocessCore.ProtocolSession`. Use it when the subprocess speaks
newline-delimited JSON-RPC and you want readiness, request ids, notifications,
peer-request replies, and interrupt/close behavior handled for you.

## Start A Session

```elixir
{:ok, session} =
  CliSubprocessCore.JSONRPC.start_link(
    command: "my-json-rpc-cli",
    args: ["serve"],
    startup_requests: [
      %{id: 0, method: "initialize", params: %{"client" => "example"}}
    ],
    notification_handler: fn notification ->
      IO.inspect({:notification, notification})
    end,
    peer_request_handler: fn request ->
      {:ok, %{"method" => request["method"], "params" => request["params"]}}
    end
  )

:ok = CliSubprocessCore.JSONRPC.await_ready(session, 5_000)

{:ok, result} =
  CliSubprocessCore.JSONRPC.request(session, "echo", %{"value" => "alpha"})

:ok = CliSubprocessCore.JSONRPC.notify(session, "ping", %{"value" => "notice"})
```

`await_ready/2` blocks until the underlying protocol session becomes ready.
With the default `:immediate` ready mode, readiness happens after startup
frames are sent. If the peer needs to emit a specific message first, set
`ready_matcher:` and wait for that event instead.

## The Main Options

Common options are:

- `:command` and `:args` for the subprocess itself
- `:startup_requests` and `:startup_notifications` for bootstrapping
- `:ready_mode` and `:ready_matcher` for readiness control
- `:notification_handler` for inbound notifications
- `:protocol_error_handler` for invalid frames or JSON-RPC errors
- `:stderr_handler` for stderr lines from the subprocess
- `:peer_request_notifier` and `:peer_request_handler` for server-initiated requests
- `:startup_timeout_ms`, `:request_timeout_ms`, and `:peer_request_timeout_ms`

All transport-facing execution-surface options still apply, including
`surface_kind` and `transport_options` for SSH-backed sessions.

## What The Helper Owns

`CliSubprocessCore.JSONRPC` handles:

- JSON encoding and decoding
- request id allocation
- response correlation
- peer-request reply encoding
- readiness and startup request flow

Provider-specific method names, params, and schemas stay outside the core.

## When To Drop Lower

If your subprocess uses the same request/reply lifecycle but not JSON-RPC, use
`CliSubprocessCore.ProtocolSession` directly with a custom
`CliSubprocessCore.ProtocolAdapter`.
