defmodule CliSubprocessCore.CommandTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Command.Error
  alias CliSubprocessCore.Command.RunResult
  alias CliSubprocessCore.CommandSpec
  alias CliSubprocessCore.TestSupport.FakeSSH
  alias CliSubprocessCore.TestSupport.ProviderProfiles.CommandRunner
  alias ExecutionPlane.Process.Transport.Surface, as: RuntimeExecutionSurface

  test "builds normalized invocations" do
    command =
      Command.new("codex", ["exec", "--json"],
        cwd: "/tmp/work",
        env: %{"OPENAI_API_KEY" => "redacted"},
        clear_env?: true,
        user: "runner"
      )

    assert command.command == "codex"
    assert command.args == ["exec", "--json"]
    assert command.cwd == "/tmp/work"
    assert command.env == %{"OPENAI_API_KEY" => "redacted"}
    assert command.clear_env? == true
    assert command.user == "runner"
    assert Command.argv(command) == ["codex", "exec", "--json"]
  end

  test "builds normalized invocations from command specs with argv prefixes" do
    spec =
      CommandSpec.new("npx", argv_prefix: ["--yes", "--package", "@google/gemini-cli", "gemini"])

    command = Command.new(spec, ["--prompt", "hello"])

    assert command.command == "npx"

    assert command.args == [
             "--yes",
             "--package",
             "@google/gemini-cli",
             "gemini",
             "--prompt",
             "hello"
           ]

    assert Command.argv(command) == [
             "npx",
             "--yes",
             "--package",
             "@google/gemini-cli",
             "gemini",
             "--prompt",
             "hello"
           ]
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

    assert {:error, {:invalid_clear_env, :invalid}} ==
             Command.validate(%Command{
               command: "amp",
               args: [],
               cwd: nil,
               env: %{},
               clear_env?: :invalid
             })

    assert {:error, {:invalid_user, 123}} ==
             Command.validate(%Command{
               command: "amp",
               args: [],
               cwd: nil,
               env: %{},
               clear_env?: false,
               user: 123
             })
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

    assert {:ok, %RunResult{} = result} =
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

  test "run/2 maps execution-plane launch failures into structured transport errors" do
    invocation = Command.new("/definitely/not/a/real/command", [])

    assert {:error, %Error{} = error} = Command.run(invocation, [])

    assert %ExecutionPlane.Process.Transport.Error{} = transport_error = elem(error.reason, 1)
    assert transport_error.reason == {:command_not_found, "/definitely/not/a/real/command"}
    assert error.context.invocation == invocation
    assert error.context.surface_kind == :local_subprocess
    assert error.context.failure_class == :launch_failed
    assert error.context.raw_payload == %{command: "/definitely/not/a/real/command"}
  end

  test "run/2 preserves execution-plane send_failed invalid_input errors" do
    invocation = Command.new(System.find_executable("sh") || "/bin/sh", ["-c", "cat > /dev/null"])
    invalid_stdin = [List.duplicate("a", 20_000), {:invalid}]

    assert {:error, %Error{} = error} =
             Command.run(invocation, stdin: invalid_stdin, timeout: 500)

    assert %ExecutionPlane.Process.Transport.Error{} = transport_error = elem(error.reason, 1)

    assert {:send_failed, {:invalid_input, %Protocol.UndefinedError{}}} =
             transport_error.reason

    assert error.context.failure_class == :launch_failed

    assert match?(
             %{send_failed: {:invalid_input, %Protocol.UndefinedError{}}},
             error.context.raw_payload
           )
  end

  test "run/2 routes execution-plane-only surface kinds through the shared runtime transport" do
    invocation = Command.new("echo", [], cwd: "/tmp/project")

    assert {:ok, runtime_surface} =
             RuntimeExecutionSurface.new(surface_kind: :test_restricted_spawn)

    assert {:error, %Error{} = error} =
             Command.run(
               invocation,
               execution_surface: runtime_surface
             )

    assert %ExecutionPlane.Process.Transport.Error{} = transport_error = elem(error.reason, 1)
    assert transport_error.reason == {:unsupported_capability, :run, :test_restricted_spawn}
    assert error.context.invocation == invocation
  end

  test "run/2 accepts execution-plane surface structs for SSH placement" do
    fake_ssh = FakeSSH.new!()
    on_exit(fn -> FakeSSH.cleanup(fake_ssh) end)

    script = create_test_script("printf 'ssh-command\\n'")

    assert {:ok, runtime_surface} =
             RuntimeExecutionSurface.new(
               surface_kind: :ssh_exec,
               target_id: "command-ssh-target",
               transport_options:
                 FakeSSH.transport_options(fake_ssh,
                   destination: "command.test.example",
                   port: 2222
                 )
             )

    assert {:ok, result} = Command.run(Command.new(script), execution_surface: runtime_surface)
    assert result.stdout == "ssh-command\n"
    assert result.exit.status == :success

    assert FakeSSH.wait_until_written(fake_ssh, 1_000) == :ok
    manifest = FakeSSH.read_manifest!(fake_ssh)
    assert manifest =~ "destination=command.test.example"
    assert manifest =~ "port=2222"
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

  test "run/2 rejects public transport-selector overrides" do
    invocation = Command.new("sh", ["-c", "printf ready"])

    assert {:error, %Error{} = error} =
             Command.run(invocation, transport_module: ExecutionPlane.Process.Transport)

    assert error.reason == {:invalid_options, {:unsupported_option, :transport_selector}}
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
