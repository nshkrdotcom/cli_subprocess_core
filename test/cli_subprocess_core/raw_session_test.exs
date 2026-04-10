defmodule CliSubprocessCore.RawSessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CliSubprocessCore.RawSession
  alias ExecutionPlane.Process.Transport
  alias ExecutionPlane.Process.Transport.RunResult

  test "raw sessions preserve exact stdin bytes and collect a normalized result" do
    script = create_test_script("cat")

    assert {:ok, session} = RawSession.start(script, [], stdin?: true, startup_mode: :lazy)

    assert session.receiver == self()
    assert session.stdout_mode == :raw
    assert session.stdin_mode == :raw
    assert session.pty? == false
    assert is_reference(session.transport_ref)
    assert :connected == RawSession.status(session)
    assert RawSession.delivery_info(session).receiver == self()
    assert RawSession.delivery_info(session).transport_ref == session.transport_ref
    assert RawSession.delivery_info(session).tagged_event_tag == session.event_tag

    assert :ok = RawSession.send_input(session, "alpha")
    assert :ok = RawSession.close_input(session)

    assert {:ok, %RunResult{} = result} = RawSession.collect(session, 2_000)
    assert result.stdout == "alpha"
    assert result.output == "alpha"
    assert result.stderr == ""
    assert result.exit.code == 0
    assert RunResult.success?(result)
  end

  test "PTY raw sessions retain PTY metadata and can be force-closed" do
    script = create_test_script("sleep 60")

    assert {:ok, session} =
             RawSession.start(script, [],
               pty?: true,
               interrupt_mode: {:stdin, <<3>>}
             )

    assert session.pty? == true

    assert %{
             delivery: %{tagged_event_tag: :cli_subprocess_core_raw_session},
             transport: %{pty?: true, interrupt_mode: {:stdin, <<3>>}}
           } = RawSession.info(session)

    transport = session.transport
    monitor = Process.monitor(transport)

    assert :ok = RawSession.force_close(session)
    assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}, 2_000
  end

  test "PTY raw sessions can collect short-lived processes without process-group startup errors" do
    script = create_test_script("printf 'ready\\n'")

    assert {:ok, session} =
             RawSession.start(script, [],
               pty?: true,
               stdin?: false
             )

    assert {:ok, %RunResult{} = result} = RawSession.collect(session, 2_000)
    assert result.exit.code == 0
    assert result.output =~ "ready"
    refute result.output =~ "Cannot set effective group to 0"
  end

  test "short-lived raw sessions disconnect cleanly after exit" do
    script = create_test_script("printf 'ready\\n'")

    Enum.each(
      [
        {"pipe", [stdin?: false]},
        {"pty", [pty?: true, stdin?: true]}
      ],
      fn {label, session_opts} ->
        assert {:ok, session} = RawSession.start(script, [], session_opts),
               "failed to start #{label} short-lived session"

        assert {:ok, %RunResult{} = result} = RawSession.collect(session, 2_000),
               "failed to collect #{label} short-lived session"

        assert result.exit.code == 0
        assert result.output =~ "ready"
        assert wait_until(fn -> RawSession.status(session) == :disconnected end, 1_000) == :ok
        assert RawSession.stderr(session) == ""
      end
    )
  end

  test "PTY close_input sends terminal EOF instead of tearing down the PTY" do
    script =
      create_python_test_script("""
      import sys

      sys.stdout.write("ready\\n")
      sys.stdout.flush()

      for line in sys.stdin:
          sys.stdout.write("ack:" + line)
          sys.stdout.flush()
      """)

    assert {:ok, session} =
             RawSession.start(script, [],
               pty?: true,
               stdin?: true,
               stdout_mode: :raw,
               stdin_mode: :raw
             )

    transport_ref = session.transport_ref

    assert_receive {:cli_subprocess_core_raw_session, ^transport_ref, {:data, "ready\r\n"}}, 2_000
    assert :ok = RawSession.send_input(session, "hello\n")

    assert_receive {:cli_subprocess_core_raw_session, ^transport_ref, {:data, "ack:hello\r\n"}},
                   2_000

    assert :ok = RawSession.close_input(session)

    assert {:ok, %RunResult{} = result} = RawSession.collect(session, 2_000)
    assert result.exit.code == 0
  end

  test "raw session delivery metadata reflects the configured tagged event atom through the core transport" do
    script = create_test_script("sleep 60")

    assert {:ok, session} =
             RawSession.start(script, [], event_tag: :requested_raw_session_tag)

    assert session.event_tag == :requested_raw_session_tag
    assert RawSession.delivery_info(session).tagged_event_tag == :requested_raw_session_tag

    assert %{delivery: %{tagged_event_tag: :requested_raw_session_tag}} =
             RawSession.info(session)

    assert :ok = RawSession.stop(session)
  end

  test "raw sessions surface generic execution metadata through transport info" do
    script = create_test_script("cat")

    assert {:ok, session} =
             RawSession.start(script, [],
               surface_kind: :local_subprocess,
               startup_mode: :lazy,
               target_id: "target-1",
               lease_ref: "lease-1",
               surface_ref: "surface-1",
               boundary_class: :local,
               observability: %{suite: :phase_b}
             )

    assert %{
             transport: %{
               surface_kind: :local_subprocess,
               target_id: "target-1",
               lease_ref: "lease-1",
               surface_ref: "surface-1",
               boundary_class: :local,
               observability: %{suite: :phase_b}
             }
           } = RawSession.info(session)

    assert :ok = RawSession.stop(session)
  end

  test "raw sessions accept generic transport overrides" do
    script = create_test_script("printf 'ready\\n'")

    assert {:ok, session} =
             RawSession.start(script, [],
               transport: Transport,
               stdin?: false
             )

    assert {:ok, %RunResult{} = result} = RawSession.collect(session, 2_000)
    assert result.output =~ "ready"
  end

  test "raw sessions reject the legacy module-selector option name" do
    assert {:error, {:unsupported_option, :transport_selector}} =
             RawSession.start("ignored", [], transport_module: Transport)
  end

  test "lazy startup surfaces subprocess spawn failures before returning a raw session" do
    missing_cwd =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_raw_session_missing_#{System.unique_integer([:positive])}"
      )

    script = create_test_script("cat")

    assert capture_log(fn ->
             assert {:error,
                     {:transport,
                      %ExecutionPlane.Process.Transport.Error{
                        reason: {:cwd_not_found, ^missing_cwd}
                      }}} =
                      RawSession.start(script, [], startup_mode: :lazy, cwd: missing_cwd)
           end) == ""
  end

  defp create_test_script(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_raw_session_#{System.unique_integer([:positive])}"
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

  defp wait_until(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        :timeout
      else
        Process.sleep(5)
        do_wait_until(fun, deadline_ms)
      end
    end
  end

  defp create_python_test_script(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_raw_session_py_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    path = Path.join(dir, "fixture.py")

    File.write!(path, """
    #!/usr/bin/env python3
    #{body}
    """)

    File.chmod!(path, 0o755)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    path
  end
end
