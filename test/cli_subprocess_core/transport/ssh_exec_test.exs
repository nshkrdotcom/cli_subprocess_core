defmodule CliSubprocessCore.Transport.SSHExecTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.ProcessExit
  alias CliSubprocessCore.TestSupport.FakeSSH
  alias CliSubprocessCore.Transport
  alias CliSubprocessCore.Transport.Error
  alias CliSubprocessCore.Transport.RunResult

  test "start/1 streams over the SSH surface and exposes generic plus adapter metadata" do
    ref = make_ref()
    fake_ssh = FakeSSH.new!()
    on_exit(fn -> FakeSSH.cleanup(fake_ssh) end)

    script =
      create_test_script("""
      input="$(cat)"
      printf 'ssh:%s\\n' "$input"
      """)

    assert {:ok, transport} =
             Transport.start(
               command: script,
               subscriber: {self(), ref},
               stdout_mode: :raw,
               stdin_mode: :raw,
               surface_kind: :static_ssh,
               target_id: "ssh-target-1",
               transport_options: [
                 ssh_path: fake_ssh.ssh_path,
                 destination: "ssh.test.example",
                 port: 2222,
                 ssh_options: [BatchMode: "yes"]
               ]
             )

    assert %Transport.Info{} = info = Transport.info(transport)
    assert info.surface_kind == :static_ssh
    assert info.target_id == "ssh-target-1"
    assert info.adapter_metadata.destination == "ssh.test.example"
    assert info.adapter_metadata.port == 2222
    assert info.adapter_metadata.ssh_path == fake_ssh.ssh_path

    assert :ok = Transport.send(transport, "alpha")
    assert :ok = Transport.end_input(transport)

    assert_receive {:cli_subprocess_core, ^ref, {:data, "ssh:alpha\n"}}, 2_000

    assert_receive {:cli_subprocess_core, ^ref, {:exit, %ProcessExit{status: :success, code: 0}}},
                   2_000

    assert FakeSSH.wait_until_written(fake_ssh, 1_000) == :ok

    manifest = FakeSSH.read_manifest!(fake_ssh)
    assert manifest =~ "destination=ssh.test.example"
    assert manifest =~ "port=2222"
  end

  test "interrupt/1 propagates through the SSH surface" do
    ref = make_ref()
    ready_path = temp_path!("interrupt_ready.txt")
    fake_ssh = FakeSSH.new!()
    on_exit(fn -> FakeSSH.cleanup(fake_ssh) end)

    script =
      create_test_script("""
      trap 'printf "interrupted\\n" >&2; exit 130' INT
      : > "#{ready_path}"
      while true; do
        sleep 0.1
      done
      """)

    assert {:ok, transport} =
             Transport.start(
               command: script,
               subscriber: {self(), ref},
               surface_kind: :leased_ssh,
               lease_ref: "lease-1",
               surface_ref: "surface-1",
               transport_options: [
                 ssh_path: fake_ssh.ssh_path,
                 destination: "leased.test.example"
               ]
             )

    assert FakeSSH.wait_until_written(fake_ssh, 1_000) == :ok
    assert wait_until(fn -> File.exists?(ready_path) end, 1_000) == :ok
    assert :ok = Transport.interrupt(transport)

    assert_receive {:cli_subprocess_core, ^ref, {:stderr, "interrupted\n"}}, 2_000

    assert_receive {:cli_subprocess_core, ^ref, {:exit, %ProcessExit{code: 130}}},
                   2_000
  end

  test "run/2 captures exact stdout, stderr, and exit data over SSHExec" do
    fake_ssh = FakeSSH.new!()
    on_exit(fn -> FakeSSH.cleanup(fake_ssh) end)

    script =
      create_test_script("""
      printf 'ssh-stdout\\n'
      printf 'ssh-stderr\\n' >&2
      exit 9
      """)

    assert {:ok, %RunResult{} = result} =
             Transport.run(
               Command.new(script),
               stderr: :separate,
               surface_kind: :static_ssh,
               transport_options: [
                 ssh_path: fake_ssh.ssh_path,
                 destination: "run.test.example"
               ]
             )

    assert result.invocation.command == script
    assert result.stdout == "ssh-stdout\n"
    assert result.stderr == "ssh-stderr\n"
    assert result.exit.status == :exit
    assert result.exit.code == 9
  end

  test "start/1 returns a structured error when SSH destination is missing" do
    assert {:error, {:transport, %Error{} = error}} =
             Transport.start(command: "cat", surface_kind: :static_ssh)

    assert error.reason == {:invalid_options, {:missing_ssh_destination, nil}}
  end

  defp create_test_script(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_transport_ssh_exec_#{System.unique_integer([:positive])}"
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

  defp temp_path!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_transport_ssh_exec_tmp_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    Path.join(dir, name)
  end

  defp wait_until(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline_ms)
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
end
