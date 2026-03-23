defmodule CliSubprocessCore.Transport.OptionsTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.{Command, Transport.Options}

  test "normalizes a Command struct into transport options" do
    command =
      Command.new("echo", ["hello"],
        cwd: "/tmp/work",
        env: %{"TERM" => "xterm-256color"},
        user: "runner"
      )

    assert {:ok, options} = Options.new(command: command, startup_mode: :lazy)

    assert options.command == "echo"
    assert options.args == ["hello"]
    assert options.cwd == "/tmp/work"
    assert options.env == %{"TERM" => "xterm-256color"}
    assert options.user == "runner"
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
               max_stderr_buffer_size: 4_096,
               replay_stderr_on_subscribe?: true
             )

    assert options.subscriber == {self(), ref}
    assert options.event_tag == :custom_transport
    assert options.headless_timeout_ms == :infinity
    assert options.max_buffer_size == 8_192
    assert options.max_stderr_buffer_size == 4_096
    assert options.replay_stderr_on_subscribe? == true
  end

  test "accepts raw PTY lifecycle settings" do
    command =
      Command.new("cat", [],
        env: %{"TERM" => "xterm-256color"},
        clear_env?: true
      )

    assert {:ok, options} =
             Options.new(
               command: command,
               stdout_mode: :raw,
               stdin_mode: :raw,
               pty?: true,
               interrupt_mode: {:stdin, <<3>>}
             )

    assert options.command == "cat"
    assert options.env == %{"TERM" => "xterm-256color"}
    assert options.clear_env? == true
    assert options.stdout_mode == :raw
    assert options.stdin_mode == :raw
    assert options.pty? == true
    assert options.interrupt_mode == {:stdin, <<3>>}
  end

  test "rejects invalid user settings" do
    assert {:error, {:invalid_transport_options, {:invalid_user, 123}}} =
             Options.new(command: "cat", user: 123)
  end

  test "rejects invalid startup and subscriber settings" do
    assert {:error, {:invalid_transport_options, :missing_command}} = Options.new(args: ["hi"])

    assert {:error, {:invalid_transport_options, {:invalid_startup_mode, :later}}} =
             Options.new(command: "cat", startup_mode: :later)

    assert {:error, {:invalid_transport_options, {:invalid_subscriber, :bad}}} =
             Options.new(command: "cat", subscriber: :bad)

    assert {:error,
            {:invalid_transport_options, {:invalid_replay_stderr_on_subscribe, :sometimes}}} =
             Options.new(command: "cat", replay_stderr_on_subscribe?: :sometimes)
  end

  test "rejects invalid raw lifecycle settings" do
    assert {:error, {:invalid_transport_options, {:invalid_stdout_mode, :chunked}}} =
             Options.new(command: "cat", stdout_mode: :chunked)

    assert {:error, {:invalid_transport_options, {:invalid_stdin_mode, :bytes}}} =
             Options.new(command: "cat", stdin_mode: :bytes)

    assert {:error, {:invalid_transport_options, {:invalid_pty, :yes}}} =
             Options.new(command: "cat", pty?: :yes)

    assert {:error, {:invalid_transport_options, {:invalid_interrupt_mode, {:stdin, :bad}}}} =
             Options.new(command: "cat", interrupt_mode: {:stdin, :bad})
  end
end
