defmodule CliSubprocessCore.Transport.ErlexecTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CliSubprocessCore.ProcessExit
  alias CliSubprocessCore.Transport
  alias CliSubprocessCore.Transport.{Erlexec, Error}

  test "eager startup streams stdout and a normalized exit to tagged subscribers" do
    ref = make_ref()
    script = create_test_script("printf 'alpha\\nbeta\\n'")

    assert {:ok, transport} = Erlexec.start(command: script, subscriber: {self(), ref})

    assert_receive {:cli_subprocess_core, ^ref, {:message, "alpha"}}, 2_000
    assert_receive {:cli_subprocess_core, ^ref, {:message, "beta"}}, 2_000

    assert_receive {:cli_subprocess_core, ^ref, {:exit, %ProcessExit{status: :success, code: 0}}},
                   2_000

    assert :disconnected == Erlexec.status(transport)
  end

  test "legacy subscribers receive bare transport tuples" do
    script = create_test_script("printf 'legacy\\n'")

    assert {:ok, _transport} = Erlexec.start(command: script, subscriber: {self(), :legacy})

    assert_receive {:transport_message, "legacy"}, 2_000
    assert_receive {:transport_exit, %ProcessExit{status: :success, code: 0}}, 2_000
  end

  test "start returns a structured error when the command cannot be spawned" do
    assert {:error, {:transport, %Error{reason: {:command_not_found, "/tmp/definitely_missing"}}}} =
             Erlexec.start(command: "/tmp/definitely_missing")
  end

  test "lazy startup returns deterministic preflight failures without booting the transport" do
    missing_cwd =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_missing_#{System.unique_integer([:positive])}"
      )

    assert capture_log(fn ->
             assert {:error, {:transport, %Error{reason: {:cwd_not_found, ^missing_cwd}}}} =
                      Erlexec.start(
                        command: System.find_executable("cat") || "/bin/cat",
                        startup_mode: :lazy,
                        cwd: missing_cwd
                      )
           end) == ""
  end

  test "send and end_input roundtrip with a custom event tag" do
    ref = make_ref()

    script =
      create_test_script("""
      while IFS= read -r line; do
        printf 'echo:%s\\n' "$line"
      done
      printf 'done\\n'
      """)

    assert {:ok, transport} =
             Erlexec.start(
               command: script,
               subscriber: {self(), ref},
               event_tag: :custom_transport
             )

    assert Transport.delivery_info(transport).tagged_event_tag == :custom_transport

    assert :ok = Transport.send(transport, ["hello"])
    assert :ok = Transport.end_input(transport)

    assert_receive message, 2_000
    assert {:ok, {:message, "echo:hello"}} = Transport.extract_event(message, ref)

    assert_receive message, 2_000
    assert {:ok, {:message, "done"}} = Transport.extract_event(message, ref)

    assert_receive message, 2_000

    assert {:ok, {:exit, %ProcessExit{status: :success, code: 0}}} =
             Transport.extract_event(message, ref)
  end

  test "buffers early events until the first subscriber attaches when configured" do
    ref = make_ref()
    long_line = String.duplicate("a", 64)
    script = create_test_script("printf '#{long_line}\\nnext\\n'")

    assert {:ok, transport} =
             Erlexec.start(
               command: script,
               max_buffer_size: 16,
               buffer_events_until_subscribe?: true
             )

    assert :ok = Transport.subscribe(transport, self(), ref)

    assert_receive {:cli_subprocess_core, ^ref,
                    {:error, %Error{reason: {:buffer_overflow, 64, 16}}}},
                   2_000

    assert_receive {:cli_subprocess_core, ^ref, {:message, "next"}}, 2_000

    assert_receive {:cli_subprocess_core, ^ref, {:exit, %ProcessExit{status: :success, code: 0}}},
                   2_000
  end

  test "raw stdout mode preserves exact bytes and exposes transport metadata" do
    ref = make_ref()
    script = create_test_script("cat")

    assert {:ok, transport} =
             Erlexec.start(
               command: script,
               subscriber: {self(), ref},
               stdout_mode: :raw,
               stdin_mode: :raw
             )

    assert %Transport.Info{} = info = Transport.info(transport)
    assert info.status == :connected
    assert info.stdout_mode == :raw
    assert info.stdin_mode == :raw
    assert info.pty? == false
    assert is_pid(info.pid)
    assert is_integer(info.os_pid)
    assert info.os_pid > 0
    assert info.delivery.legacy? == true
    assert info.delivery.tagged_event_tag == :cli_subprocess_core

    assert :ok = Transport.send(transport, "alpha")
    assert :ok = Transport.end_input(transport)

    assert_receive {:cli_subprocess_core, ^ref, {:data, "alpha"}}, 2_000

    assert_receive {:cli_subprocess_core, ^ref, {:exit, %ProcessExit{status: :success, code: 0}}},
                   2_000
  end

  test "configured stdin interrupt payloads are written exactly to stdin" do
    ref = make_ref()

    script =
      create_test_script("""
      IFS= read -r line

      if [ "$line" = "quit" ]; then
        exit 130
      fi

      exit 1
      """)

    assert {:ok, transport} =
             Erlexec.start(
               command: script,
               subscriber: {self(), ref},
               stdout_mode: :raw,
               stdin_mode: :raw,
               interrupt_mode: {:stdin, "quit\n"}
             )

    assert %Transport.Info{pty?: false, interrupt_mode: {:stdin, "quit\n"}} =
             Transport.info(transport)

    assert :ok = Transport.interrupt(transport)

    assert_receive {:cli_subprocess_core, ^ref, {:exit, %ProcessExit{code: 130}}},
                   2_000
  end

  test "close_stdin_on_start closes stdin immediately after boot" do
    ref = make_ref()

    script =
      create_test_script("""
      cat >/dev/null
      printf 'done\\n'
      """)

    assert {:ok, _transport} =
             Erlexec.start(
               command: script,
               subscriber: {self(), ref},
               close_stdin_on_start?: true
             )

    assert_receive {:cli_subprocess_core, ^ref, {:message, "done"}}, 2_000

    assert_receive {:cli_subprocess_core, ^ref, {:exit, %ProcessExit{status: :success, code: 0}}},
                   2_000
  end

  test "last unsubscribe starts the headless timeout" do
    script =
      create_test_script("""
      while IFS= read -r line; do
        printf '%s\\n' "$line"
      done
      """)

    assert {:ok, transport} =
             Erlexec.start(command: script, headless_timeout_ms: 50)

    monitor = Process.monitor(transport)
    assert :ok = Transport.subscribe(transport, self())
    assert :ok = Transport.unsubscribe(transport, self())

    assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}, 2_000
  end

  test "monitor-based subscriber cleanup keeps the transport alive until the last subscriber leaves" do
    ref = make_ref()

    script =
      create_test_script("""
      while IFS= read -r line; do
        printf '%s\\n' "$line"
      done
      """)

    assert {:ok, transport} =
             Erlexec.start(command: script, subscriber: {self(), ref}, headless_timeout_ms: 100)

    parent = self()
    child_ref = make_ref()

    child =
      spawn(fn ->
        :ok = Transport.subscribe(transport, self(), child_ref)
        send(parent, :child_subscribed)

        receive do
          {:cli_subprocess_core, ^child_ref, {:message, line}} ->
            send(parent, {:child_message, line})

          :stop ->
            :ok
        end
      end)

    assert_receive :child_subscribed, 1_000

    assert :ok = Transport.send(transport, "fanout")
    assert_receive {:cli_subprocess_core, ^ref, {:message, "fanout"}}, 2_000
    assert_receive {:child_message, "fanout"}, 2_000

    child_monitor = Process.monitor(child)
    send(child, :stop)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, reason}, 2_000
    assert reason in [:normal, :noproc]

    assert :connected == Transport.status(transport)
    assert :ok = Transport.unsubscribe(transport, self())
  end

  test "stderr is dispatched in realtime, retained in a ring buffer, and callback lines flush on exit" do
    ref = make_ref()
    parent = self()

    script =
      create_test_script("""
      printf 'err-one\\nerr-two' >&2
      sleep 0.1
      printf 'out\\n'
      """)

    assert {:ok, _transport} =
             Erlexec.start(
               command: script,
               subscriber: {self(), ref},
               max_stderr_buffer_size: 8,
               stderr_callback: fn line -> send(parent, {:stderr_line, line}) end
             )

    assert_receive {:stderr_line, "err-one"}, 2_000
    assert_receive {:cli_subprocess_core, ^ref, {:stderr, stderr_chunk}}, 2_000

    trailing_stderr =
      receive do
        {:cli_subprocess_core, ^ref, {:stderr, chunk}} -> chunk
      after
        250 -> ""
      end

    combined_stderr = stderr_chunk <> trailing_stderr
    assert combined_stderr =~ "err-one"
    assert combined_stderr =~ "err-two"
    assert_receive {:cli_subprocess_core, ^ref, {:message, "out"}}, 2_000
    assert_receive {:stderr_line, "err-two"}, 2_000

    assert_receive {:cli_subprocess_core, ^ref,
                    {:exit, %ProcessExit{status: :success, code: 0, stderr: "\nerr-two"}}},
                   2_000
  end

  test "extract_event unwraps legacy transport tuples" do
    assert {:ok, {:message, "legacy"}} = Transport.extract_event({:transport_message, "legacy"})
    assert :error = Transport.extract_event({:unexpected, :message})
  end

  test "late subscribers can receive the retained stderr tail from the core" do
    ref = make_ref()

    script =
      create_test_script("""
      printf 'late stderr' >&2
      sleep 0.1
      """)

    assert {:ok, transport} =
             Erlexec.start(
               command: script,
               replay_stderr_on_subscribe?: true
             )

    Process.sleep(20)

    assert :ok = Transport.subscribe(transport, self(), ref)

    assert_receive {:cli_subprocess_core, ^ref, {:stderr, "late stderr"}}, 2_000

    assert_receive {:cli_subprocess_core, ^ref,
                    {:exit, %ProcessExit{status: :success, code: 0, stderr: "late stderr"}}},
                   2_000
  end

  test "fast-exit stderr is retained for late subscribers" do
    ref = make_ref()
    script = create_test_script("printf 'fast stderr' >&2")

    assert {:ok, transport} =
             Erlexec.start(
               command: script,
               replay_stderr_on_subscribe?: true
             )

    assert :ok = Transport.subscribe(transport, self(), ref)

    assert_receive {:cli_subprocess_core, ^ref, {:stderr, "fast stderr"}}, 2_000

    assert_receive {:cli_subprocess_core, ^ref,
                    {:exit, %ProcessExit{status: :success, code: 0, stderr: "fast stderr"}}},
                   2_000
  end

  test "oversized stdout emits a structured overflow error and recovers at the next newline" do
    ref = make_ref()

    script =
      create_test_script("""
      python3 - <<'PY'
      print('x' * 2048)
      print('after')
      PY
      """)

    assert {:ok, _transport} =
             Erlexec.start(
               command: script,
               subscriber: {self(), ref},
               max_buffer_size: 128
             )

    assert_receive {:cli_subprocess_core, ^ref,
                    {:error, %Error{reason: {:buffer_overflow, actual_size, 128}}}},
                   5_000

    assert actual_size > 128
    assert_receive {:cli_subprocess_core, ^ref, {:message, "after"}}, 5_000
  end

  test "large stdout fragments below the buffer limit are flushed intact on exit" do
    ref = make_ref()
    large_line = String.duplicate("x", 262_144)

    script =
      create_test_script("""
      python3 - <<'PY'
      import sys
      sys.stdout.write("x" * 262144)
      PY
      """)

    assert {:ok, _transport} =
             Erlexec.start(
               command: script,
               subscriber: {self(), ref},
               max_buffer_size: byte_size(large_line) + 1_024
             )

    assert_receive {:cli_subprocess_core, ^ref, {:message, ^large_line}}, 5_000

    assert_receive {:cli_subprocess_core, ^ref, {:exit, %ProcessExit{status: :success, code: 0}}},
                   5_000
  end

  test "post-exit stdout flush preserves the trailing fragment exactly" do
    ref = make_ref()
    fragment = "  trailing fragment  "
    script = create_test_script("printf '#{fragment}'")

    assert {:ok, _transport} = Erlexec.start(command: script, subscriber: {self(), ref})

    assert_receive {:cli_subprocess_core, ^ref, {:message, ^fragment}}, 2_000

    assert_receive {:cli_subprocess_core, ^ref, {:exit, %ProcessExit{status: :success, code: 0}}},
                   2_000
  end

  test "interrupt supports in-flight subprocesses and surfaces the resulting exit" do
    ref = make_ref()

    script =
      create_test_script("""
      trap 'printf "interrupted\\n" >&2; exit 130' INT
      sleep 60
      """)

    assert {:ok, transport} = Erlexec.start(command: script, subscriber: {self(), ref})

    assert :ok = Transport.interrupt(transport)

    assert_receive {:cli_subprocess_core, ^ref, {:exit, %ProcessExit{} = exit}}, 2_000
    refute ProcessExit.successful?(exit)
  end

  test "interrupt and close races complete without leaving the caller hanging" do
    script =
      create_test_script("""
      trap 'exit 130' INT
      sleep 60
      """)

    assert {:ok, transport} = Erlexec.start(command: script)

    interrupt_task =
      Task.async(fn ->
        Transport.interrupt(transport)
      end)

    assert :ok = Transport.close(transport)

    case Task.await(interrupt_task, 2_000) do
      :ok ->
        :ok

      {:error, {:transport, %Error{reason: :not_connected}}} ->
        :ok

      {:error, {:transport, %Error{reason: :transport_stopped}}} ->
        :ok
    end
  end

  test "force_close stops the transport immediately" do
    script = create_test_script("sleep 60")

    assert {:ok, transport} = Erlexec.start(command: script)
    monitor = Process.monitor(transport)

    assert :ok = Transport.force_close(transport)
    assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}, 2_000
  end

  test "safe_call returns a timeout without killing a suspended transport" do
    script = create_test_script("sleep 60")

    assert {:ok, transport} = Erlexec.start(command: script)

    try do
      monitor = Process.monitor(transport)
      :ok = :sys.suspend(transport)

      assert {:error, {:transport, %Error{reason: :timeout}}} =
               Transport.force_close(transport)

      assert Process.alive?(transport)
      refute_received {:DOWN, ^monitor, :process, ^transport, _reason}

      :ok = :sys.resume(transport)
      assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}, 2_000
    after
      if Process.alive?(transport) do
        Process.exit(transport, :kill)
      end
    end
  end

  test "calls after transport exit return structured not_connected errors" do
    script = create_test_script("exit 0")

    assert {:ok, transport} = Erlexec.start(command: script)
    monitor = Process.monitor(transport)

    assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}, 2_000

    assert {:error, {:transport, %Error{reason: :not_connected}}} =
             Transport.send(transport, "hello")

    assert {:error, {:transport, %Error{reason: :not_connected}}} =
             Transport.end_input(transport)

    assert {:error, {:transport, %Error{reason: :not_connected}}} =
             Transport.interrupt(transport)

    assert :disconnected == Transport.status(transport)
    assert "" == Transport.stderr(transport)
  end

  defp create_test_script(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_transport_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    path = Path.join(dir, "fixture.sh")

    File.write!(path, """
    #!/usr/bin/env bash
    set -euo pipefail
    #{body}
    """)

    File.chmod!(path, 0o755)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    path
  end
end
