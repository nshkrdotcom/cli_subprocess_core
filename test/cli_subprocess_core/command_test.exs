defmodule CliSubprocessCore.CommandTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Command

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
end
