defmodule CliSubprocessCore.ProtocolSessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CliSubprocessCore.ProtocolSession
  alias CliSubprocessCore.TestSupport
  alias CliSubprocessCore.TestSupport.FakeSSH

  test "protocol sessions handle startup, requests, notifications, and peer requests locally" do
    {:ok, session} =
      start_protocol_session(fn request ->
        {:ok, %{"method" => request["method"], "params" => request["params"]}}
      end)

    on_exit(fn -> ProtocolSession.close(session) end)

    assert :ok = ProtocolSession.await_ready(session, 1_000)
    assert_receive {:protocol_notification, %{"method" => "server_ready"}}, 1_000

    assert {:ok, %{"value" => "alpha"}} =
             ProtocolSession.request(session, %{method: "echo", params: %{"value" => "alpha"}})

    assert :ok =
             ProtocolSession.notify(session, %{
               method: "notify_test",
               params: %{"value" => "notice"}
             })

    assert_receive {:protocol_notification,
                    %{"method" => "server_notice", "params" => %{"value" => "notice"}}},
                   1_000

    assert {:ok,
            %{
              "peer_reply" => %{
                "result" => %{"method" => "client.echo", "params" => %{"value" => "pong"}}
              }
            }} =
             ProtocolSession.request(session, %{
               method: "trigger_peer",
               params: %{id: "peer-ok", method: "client.echo", params: %{"value" => "pong"}}
             })

    assert %{phase: :ready, pending_requests: 0} = ProtocolSession.info(session)
  end

  test "protocol sessions run over fake SSH" do
    fake_ssh = FakeSSH.new!()
    on_exit(fn -> FakeSSH.cleanup(fake_ssh) end)

    {:ok, session} =
      start_protocol_session(
        fn request -> {:ok, %{"method" => request["method"]}} end,
        surface_kind: :ssh_exec,
        transport_options:
          FakeSSH.transport_options(fake_ssh,
            destination: "protocol.test.example",
            port: 2222
          )
      )

    on_exit(fn -> ProtocolSession.close(session) end)

    assert :ok = ProtocolSession.await_ready(session, 1_000)

    assert {:ok, %{"value" => "ssh"}} =
             ProtocolSession.request(session, %{method: "echo", params: %{"value" => "ssh"}})

    assert FakeSSH.wait_until_written(fake_ssh, 1_000) == :ok
    assert FakeSSH.read_manifest!(fake_ssh) =~ "destination=protocol.test.example"
  end

  test "peer request notifier preserves inbound ordering relative to later notifications" do
    test_pid = self()

    {:ok, session} =
      start_protocol_session(
        fn _request ->
          Process.sleep(50)
          {:ok, %{"ack" => true}}
        end,
        peer_request_notifier: fn correlation_key, request ->
          send(test_pid, {:peer_request_notified, correlation_key, request["method"]})
        end
      )

    on_exit(fn -> ProtocolSession.close(session) end)

    assert :ok = ProtocolSession.await_ready(session, 1_000)
    assert_receive {:protocol_notification, %{"method" => "server_ready"}}, 1_000

    task =
      Task.async(fn ->
        ProtocolSession.request(session, %{
          method: "trigger_peer_and_notice",
          params: %{id: "peer-order", method: "client.echo", params: %{"value" => "pong"}}
        })
      end)

    assert_receive {:peer_request_notified, "peer-order", "client.echo"}, 1_000

    assert_receive {:protocol_notification,
                    %{"method" => "after_peer", "params" => %{"id" => "peer-order"}}},
                   1_000

    assert {:ok, %{"peer_reply" => %{"result" => %{"ack" => true}}}} = Task.await(task, 1_000)
  end

  test "peer request handler error replies at the protocol level and keeps the session alive" do
    assert_peer_request_failure(
      fn _request -> {:error, %{"code" => -32_011, "message" => "denied"}} end,
      fn reply ->
        assert %{"error" => %{"code" => -32_011, "message" => "denied"}, "id" => "peer-failure"} =
                 reply
      end,
      peer_request_timeout_ms: 1_000
    )
  end

  test "peer request handler throw replies at the protocol level and keeps the session alive" do
    log =
      capture_log(fn ->
        assert_peer_request_failure(
          fn _request -> throw(:boom) end,
          fn reply ->
            assert %{
                     "error" => %{"code" => -32_000, "message" => "peer request handler exited"},
                     "id" => "peer-failure"
                   } = reply
          end,
          peer_request_timeout_ms: 1_000
        )
      end)

    assert log =~ "Task #PID<"
    assert log =~ "terminating"
    assert log =~ "{:nocatch, :boom}"
  end

  test "peer request handler exit replies at the protocol level and keeps the session alive" do
    log =
      capture_log(fn ->
        assert_peer_request_failure(
          fn _request -> exit(:boom) end,
          fn reply ->
            assert %{
                     "error" => %{"code" => -32_000, "message" => "peer request handler exited"},
                     "id" => "peer-failure"
                   } = reply
          end,
          peer_request_timeout_ms: 1_000
        )
      end)

    assert log =~ "Task #PID<"
    assert log =~ "terminating"
    assert log =~ "** (stop) :boom"
  end

  test "peer request handler timeout replies at the protocol level and keeps the session alive" do
    assert_peer_request_failure(
      fn _request ->
        Process.sleep(100)
        {:ok, %{"late" => true}}
      end,
      fn reply ->
        assert %{
                 "error" => %{"code" => -32_000, "message" => "peer request handler timed out"},
                 "id" => "peer-failure"
               } = reply
      end,
      peer_request_timeout_ms: 10
    )
  end

  test "successful channel exit stops the protocol session normally" do
    original = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, original) end)

    {:ok, session} =
      start_protocol_session(fn request ->
        {:ok, %{"method" => request["method"], "params" => request["params"]}}
      end)

    ref = Process.monitor(session)

    assert :ok = ProtocolSession.await_ready(session, 1_000)

    assert {:ok, %{"ok" => true}} =
             ProtocolSession.request(session, %{method: "shutdown", params: %{}})

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 1_000
  end

  defp assert_peer_request_failure(handler, assert_reply, opts) do
    {:ok, session} = start_protocol_session(handler, opts)
    on_exit(fn -> ProtocolSession.close(session) end)

    assert :ok = ProtocolSession.await_ready(session, 1_000)

    assert {:ok, %{"peer_reply" => reply}} =
             ProtocolSession.request(session, %{
               method: "trigger_peer",
               params: %{
                 id: "peer-failure",
                 method: "client.failure",
                 params: %{"value" => "alpha"}
               }
             })

    assert_reply.(reply)

    assert {:ok, %{"ok" => true}} =
             ProtocolSession.request(session, %{method: "echo", params: %{"ok" => true}})

    assert %{phase: :ready} = ProtocolSession.info(session)
  end

  defp start_protocol_session(handler, opts \\ [])
       when is_function(handler, 1) and is_list(opts) do
    test_pid = self()
    script = create_protocol_server_script()

    ProtocolSession.start_link(
      [
        adapter: ExecutionPlane.Protocols.JsonRpc.Adapter,
        adapter_options: [request_id_start: 1],
        command: script,
        startup_requests: [%{id: 0, method: "initialize", params: %{"client" => "test"}}],
        ready_mode: :startup_complete,
        notification_handler: fn notification ->
          send(test_pid, {:protocol_notification, notification})
        end,
        peer_request_handler: handler
      ] ++ opts
    )
  end

  defp create_protocol_server_script do
    python =
      System.find_executable("python3") || System.find_executable("python") ||
        raise "python is required for protocol session tests"

    dir = TestSupport.tmp_dir!("cli_subprocess_core_protocol_session")
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
          elif message.get("method") == "trigger_peer_and_notice":
              peer = message.get("params", {})
              send(
                  {
                      "id": peer.get("id", "peer-1"),
                      "method": peer.get("method", "client.echo"),
                      "params": peer.get("params", {}),
                  }
              )
              send({"method": "after_peer", "params": {"id": peer.get("id", "peer-1")}})
              reply = json.loads(sys.stdin.readline())
              send({"id": message["id"], "result": {"peer_reply": reply}})
          elif message.get("method") == "shutdown":
              send({"id": message["id"], "result": {"ok": True}})
              break
          elif "id" in message:
              send({"id": message["id"], "result": message.get("params")})
      """
    )
  end
end
