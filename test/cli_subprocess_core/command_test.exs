defmodule CliSubprocessCore.CommandTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Command.Error
  alias CliSubprocessCore.TestSupport.ProviderProfiles.CommandRunner

  test "builds normalized invocations" do
    command =
      Command.new("codex", ["exec", "--json"],
        cwd: "/tmp/work",
        env: %{"OPENAI_API_KEY" => "redacted"}
      )

    assert command.command == "codex"
    assert command.args == ["exec", "--json"]
    assert command.cwd == "/tmp/work"
    assert command.env == %{"OPENAI_API_KEY" => "redacted"}
    assert Command.argv(command) == ["codex", "exec", "--json"]
  end

  test "validates the invocation contract" do
    assert :ok == Command.validate(Command.new("amp", ["run"]))

    assert {:error, {:invalid_command, nil}} ==
             Command.validate(%Command{command: nil, args: [], cwd: nil, env: %{}})

    assert {:error, {:invalid_args, [1]}} ==
             Command.validate(%Command{command: "amp", args: [1], cwd: nil, env: %{}})

    assert {:error, {:invalid_cwd, 123}} ==
             Command.validate(%Command{command: "amp", args: [], cwd: 123, env: %{}})

    assert {:error, {:invalid_env, [bad: "env"]}} ==
             Command.validate(%Command{command: "amp", args: [], cwd: nil, env: [bad: "env"]})
  end

  test "merges environment data immutably" do
    command = Command.new("gemini", ["chat"], env: %{"HOME" => "/tmp"})
    updated = Command.put_env(command, "DEBUG", "1")

    assert command.env == %{"HOME" => "/tmp"}
    assert updated.env == %{"DEBUG" => "1", "HOME" => "/tmp"}

    merged = Command.merge_env(updated, %{"HOME" => "/opt/work", "TERM" => "xterm-256color"})

    assert merged.env == %{
             "DEBUG" => "1",
             "HOME" => "/opt/work",
             "TERM" => "xterm-256color"
           }
  end

  test "run/1 resolves a provider profile and executes through the shared transport lane" do
    stdin_path = temp_path!("stdin.txt")

    script =
      create_test_script("""
      cat > "#{stdin_path}"
      printf 'runner-ok'
      """)

    assert {:ok, result} =
             Command.run(
               profile: CommandRunner,
               command: script,
               args: ["--ignored"],
               stdin: "payload-without-newline"
             )

    assert result.invocation.command == script
    assert result.invocation.args == ["--ignored"]
    assert result.stdout == "runner-ok"
    assert result.stderr == ""
    assert result.output == "runner-ok"
    assert result.exit.status == :success
    assert File.read!(stdin_path) == "payload-without-newline"
  end

  test "run/1 returns a structured error when the provider cannot be resolved" do
    assert {:error, %Error{} = error} = Command.run(provider: :missing_phase_2a_provider)

    assert error.reason == {:provider_not_found, :missing_phase_2a_provider}
    assert error.context == %{provider: :missing_phase_2a_provider}
  end

  test "run/1 wraps invalid command-lane options in Command.Error" do
    assert {:error, %Error{} = error} =
             Command.run(
               profile: CommandRunner,
               command: System.find_executable("sh") || "/bin/sh",
               timeout: -1
             )

    assert error.reason == {:invalid_options, {:invalid_timeout, -1}}
    assert error.message == "Invalid command options: {:invalid_timeout, -1}"
  end

  test "run/2 wraps invalid command-lane options in Command.Error with invocation context" do
    invocation = Command.new("sh", ["-c", "printf ready"])

    assert {:error, %Error{} = error} = Command.run(invocation, timeout: -1)

    assert error.reason == {:invalid_options, {:invalid_timeout, -1}}
    assert error.context == %{invocation: invocation}
  end

  defp create_test_script(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_command_#{System.unique_integer([:positive])}"
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
        "cli_subprocess_core_command_tmp_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    Path.join(dir, name)
  end
end
