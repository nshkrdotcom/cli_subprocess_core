defmodule CliSubprocessCore.RawSessionTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.RawSession
  alias CliSubprocessCore.Transport.RunResult

  test "raw sessions preserve exact stdin bytes and collect a normalized result" do
    script = create_test_script("cat")

    assert {:ok, session} = RawSession.start(script, [], stdin?: true, startup_mode: :lazy)

    assert session.receiver == self()
    assert session.stdout_mode == :raw
    assert session.stdin_mode == :raw
    assert session.pty? == false
    assert is_reference(session.transport_ref)
    assert :connected == RawSession.status(session)

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
    assert %{transport: %{pty?: true, interrupt_mode: {:stdin, <<3>>}}} = RawSession.info(session)

    transport = session.transport
    monitor = Process.monitor(transport)

    assert :ok = RawSession.force_close(session)
    assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}, 2_000
  end

  test "lazy startup surfaces subprocess spawn failures before returning a raw session" do
    missing_cwd =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_raw_session_missing_#{System.unique_integer([:positive])}"
      )

    script = create_test_script("cat")

    assert {:error,
            {:transport,
             %CliSubprocessCore.Transport.Error{reason: {:cwd_not_found, ^missing_cwd}}}} =
             RawSession.start(script, [], startup_mode: :lazy, cwd: missing_cwd)
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
end
