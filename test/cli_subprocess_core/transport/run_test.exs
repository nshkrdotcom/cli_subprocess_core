defmodule CliSubprocessCore.Transport.RunTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Transport
  alias CliSubprocessCore.Transport.Error
  alias CliSubprocessCore.Transport.RunResult

  test "run/2 captures exact stdout, stderr, and normalized exit data" do
    script =
      create_test_script("""
      printf 'stdout-line\\n'
      printf 'stderr-line\\n' >&2
      exit 7
      """)

    assert {:ok, %RunResult{} = result} =
             Transport.run(Command.new(script), stderr: :separate)

    assert result.invocation.command == script
    assert result.stdout == "stdout-line\n"
    assert result.stderr == "stderr-line\n"
    assert result.output == "stdout-line\n"
    assert result.stderr_mode == :separate
    assert result.exit.status == :exit
    assert result.exit.code == 7
    refute RunResult.success?(result)
  end

  test "run/2 preserves exact stdin bytes and can merge stderr into output" do
    stdin_path = temp_path!("stdin.txt")

    script =
      create_test_script("""
      cat > "#{stdin_path}"
      printf 'out'
      printf 'err' >&2
      """)

    assert {:ok, %RunResult{} = result} =
             Transport.run(
               Command.new(script),
               stdin: "stdin-without-newline",
               stderr: :stdout
             )

    assert File.read!(stdin_path) == "stdin-without-newline"
    assert result.stdout == "out"
    assert result.stderr == "err"
    assert result.output == "outerr"
    assert result.stderr_mode == :stdout
    assert RunResult.success?(result)
  end

  test "run/2 times out, stops the subprocess, and returns partial capture context" do
    pid_file = temp_path!("pid.txt")

    script =
      create_test_script("""
      echo $$ > "#{pid_file}"
      printf 'tick'
      tail -f /dev/null
      """)

    assert {:error, {:transport, %Error{} = error}} =
             Transport.run(Command.new(script), timeout: 20)

    assert error.reason == :timeout
    assert error.context.stdout == "tick"
    assert error.context.output == "tick"
    assert error.context.command == script

    assert wait_until(fn -> File.exists?(pid_file) end, 1_000) == :ok

    os_pid =
      pid_file
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    assert wait_until(fn -> not os_process_alive?(os_pid) end, 2_500) == :ok
  end

  test "run/2 can clear inherited environment while keeping explicit overrides" do
    env_key = "CLI_SUBPROCESS_CORE_PHASE2A_ENV"
    previous = System.get_env(env_key)
    System.put_env(env_key, "present")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env(env_key)
        value -> System.put_env(env_key, value)
      end
    end)

    script =
      create_test_script("""
      if [ -n "${#{env_key}:-}" ]; then
        printf 'present'
      else
        printf 'missing'
      fi
      """)

    assert {:ok, %RunResult{} = result} =
             Transport.run(
               Command.new(script,
                 env: %{"PATH" => System.get_env("PATH") || ""},
                 clear_env?: true
               )
             )

    assert result.stdout == "missing"
    assert RunResult.success?(result)
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

  defp os_process_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp create_test_script(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_transport_run_#{System.unique_integer([:positive])}"
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
        "cli_subprocess_core_transport_run_tmp_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    Path.join(dir, name)
  end
end
