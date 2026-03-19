defmodule CliSubprocessCore.Transport.OptionsTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.{Command, Transport.Options}

  test "normalizes a Command struct into transport options" do
    command =
      Command.new("echo", ["hello"],
        cwd: "/tmp/work",
        env: %{"TERM" => "xterm-256color"}
      )

    assert {:ok, options} = Options.new(command: command, startup_mode: :lazy)

    assert options.command == "echo"
    assert options.args == ["hello"]
    assert options.cwd == "/tmp/work"
    assert options.env == %{"TERM" => "xterm-256color"}
    assert options.startup_mode == :lazy
    assert options.event_tag == :cli_subprocess_core
    assert options.task_supervisor == CliSubprocessCore.TaskSupervisor
  end

  test "accepts explicit subscriber tuples and configured limits" do
    ref = make_ref()

    assert {:ok, options} =
             Options.new(
               command: "cat",
               subscriber: {self(), ref},
               event_tag: :custom_transport,
               headless_timeout_ms: :infinity,
               max_buffer_size: 8_192,
               max_stderr_buffer_size: 4_096
             )

    assert options.subscriber == {self(), ref}
    assert options.event_tag == :custom_transport
    assert options.headless_timeout_ms == :infinity
    assert options.max_buffer_size == 8_192
    assert options.max_stderr_buffer_size == 4_096
  end

  test "rejects invalid startup and subscriber settings" do
    assert {:error, {:invalid_transport_options, :missing_command}} = Options.new(args: ["hi"])

    assert {:error, {:invalid_transport_options, {:invalid_startup_mode, :later}}} =
             Options.new(command: "cat", startup_mode: :later)

    assert {:error, {:invalid_transport_options, {:invalid_subscriber, :bad}}} =
             Options.new(command: "cat", subscriber: :bad)
  end
end
