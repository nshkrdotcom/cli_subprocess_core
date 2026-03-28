defmodule CliSubprocessCore.JSONRPCTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.JSONRPC
  alias CliSubprocessCore.TestSupport

  test "json-rpc helper supports requests, notifications, and inbound peer requests" do
    test_pid = self()
    script = create_protocol_server_script()

    assert {:ok, session} =
             JSONRPC.start_link(
               command: script,
               startup_requests: [
                 %{id: 0, method: "initialize", params: %{"client" => "json-rpc-test"}}
               ],
               notification_handler: fn notification ->
                 send(test_pid, {:json_rpc_notification, notification})
               end,
               peer_request_handler: fn request ->
                 {:ok, %{"method" => request["method"], "params" => request["params"]}}
               end
             )

    on_exit(fn -> JSONRPC.close(session) end)

    assert :ok = JSONRPC.await_ready(session, 1_000)
    assert_receive {:json_rpc_notification, %{"method" => "server_ready"}}, 1_000

    assert {:ok, %{"value" => "alpha"}} =
             JSONRPC.request(session, "echo", %{"value" => "alpha"})

    assert :ok = JSONRPC.notify(session, "notify_test", %{"value" => "notice"})

    assert_receive {:json_rpc_notification,
                    %{"method" => "server_notice", "params" => %{"value" => "notice"}}},
                   1_000

    assert {:ok,
            %{
              "peer_reply" => %{
                "result" => %{"method" => "client.echo", "params" => %{"value" => "pong"}}
              }
            }} =
             JSONRPC.request(session, "trigger_peer", %{
               "id" => "json-rpc-peer",
               "method" => "client.echo",
               "params" => %{"value" => "pong"}
             })
  end

  defp create_protocol_server_script do
    python =
      System.find_executable("python3") || System.find_executable("python") ||
        raise "python is required for JSON-RPC tests"

    dir = TestSupport.tmp_dir!("cli_subprocess_core_json_rpc")
    on_exit(fn -> File.rm_rf!(dir) end)

    TestSupport.write_executable!(
      dir,
      "server.py",
      """
      #!#{python}
      import json
      import sys

      def send(message):
          sys.stdout.write(json.dumps(message) + "\\n")
          sys.stdout.flush()

      for raw in sys.stdin:
          raw = raw.strip()
          if not raw:
              continue

          message = json.loads(raw)

          if message.get("method") == "initialize":
              send({"id": message["id"], "result": {"ready": True}})
              send({"method": "server_ready", "params": {"phase": "boot"}})
          elif message.get("method") == "echo":
              send({"id": message["id"], "result": message.get("params")})
          elif message.get("method") == "notify_test":
              send({"method": "server_notice", "params": message.get("params")})
          elif message.get("method") == "trigger_peer":
              peer = message.get("params", {})
              send(
                  {
                      "id": peer.get("id", "peer-1"),
                      "method": peer.get("method", "client.echo"),
                      "params": peer.get("params", {}),
                  }
              )
              reply = json.loads(sys.stdin.readline())
              send({"id": message["id"], "result": {"peer_reply": reply}})
          elif "id" in message:
              send({"id": message["id"], "result": message.get("params")})
      """
    )
  end
end
