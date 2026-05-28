defmodule CliSubprocessCore.ProviderProfiles.AntigravityTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfiles.Antigravity
  alias ExecutionPlane.ProcessExit

  describe "build_invocation/1" do
    test "builds the basic agy print invocation" do
      assert {:ok, command} = Antigravity.build_invocation(command: "agy-bin", prompt: "hello")

      assert command.command == "agy-bin"
      assert command.args == ["--print", "hello"]
    end

    test "adds sandbox as a boolean flag" do
      assert {:ok, command} =
               Antigravity.build_invocation(command: "agy-bin", prompt: "hello", sandbox: true)

      assert command.args == ["--print", "hello", "--sandbox"]
    end

    test "adds dangerously skip permissions from the direct option" do
      assert {:ok, command} =
               Antigravity.build_invocation(
                 command: "agy-bin",
                 prompt: "hello",
                 dangerously_skip_permissions: true
               )

      assert command.args == ["--print", "hello", "--dangerously-skip-permissions"]
    end

    test "adds dangerously skip permissions from provider permission mode" do
      assert {:ok, command} =
               Antigravity.build_invocation(
                 command: "agy-bin",
                 prompt: "hello",
                 permission_mode: :bypass
               )

      assert command.args == ["--print", "hello", "--dangerously-skip-permissions"]
    end

    test "does not duplicate skip permissions when both aliases are set" do
      assert {:ok, command} =
               Antigravity.build_invocation(
                 command: "agy-bin",
                 prompt: "hello",
                 dangerously_skip_permissions: true,
                 permission_mode: :bypass
               )

      assert command.args == ["--print", "hello", "--dangerously-skip-permissions"]
    end

    test "adds one repeatable add-dir flag" do
      assert {:ok, command} =
               Antigravity.build_invocation(
                 command: "agy-bin",
                 prompt: "hello",
                 add_dirs: ["/workspace/one"]
               )

      assert command.args == ["--print", "hello", "--add-dir", "/workspace/one"]
    end

    test "adds multiple repeatable add-dir flags without comma joining" do
      assert {:ok, command} =
               Antigravity.build_invocation(
                 command: "agy-bin",
                 prompt: "hello",
                 add_dirs: ["/workspace/one", "/workspace/two"]
               )

      assert command.args == [
               "--print",
               "hello",
               "--add-dir",
               "/workspace/one",
               "--add-dir",
               "/workspace/two"
             ]
    end

    test "adds conversation and continue flags" do
      assert {:ok, command} =
               Antigravity.build_invocation(
                 command: "agy-bin",
                 prompt: "hello",
                 conversation: "abc",
                 continue: true
               )

      assert command.args == ["--print", "hello", "--conversation", "abc", "--continue"]
    end

    test "adds optional print-timeout and log-file flags from the verified agy surface" do
      assert {:ok, command} =
               Antigravity.build_invocation(
                 command: "agy-bin",
                 prompt: "hello",
                 print_timeout: "30s",
                 log_file: "/tmp/agy.log"
               )

      assert command.args == [
               "--print",
               "hello",
               "--print-timeout",
               "30s",
               "--log-file",
               "/tmp/agy.log"
             ]
    end

    test "requires prompt" do
      assert {:error, {:missing_option, :prompt}} =
               Antigravity.build_invocation(command: "agy-bin")
    end
  end

  describe "decode_stdout/2" do
    test "maps normal text lines to assistant deltas" do
      state = Antigravity.init_parser_state([])

      assert {[event], next_state} = Antigravity.decode_stdout("ANTIGRAVITY_OK", state)
      assert event.kind == :assistant_delta
      assert event.provider == :antigravity
      assert %Payload.AssistantDelta{content: "ANTIGRAVITY_OK"} = event.payload
      assert next_state.emitted == 1
    end

    test "drops empty and whitespace-only lines" do
      state = Antigravity.init_parser_state([])

      assert {[], ^state} = Antigravity.decode_stdout("", state)
      assert {[], ^state} = Antigravity.decode_stdout("   ", state)
    end
  end

  describe "handle_exit/2" do
    test "emits a result on successful process exit after content" do
      state = Antigravity.init_parser_state([])
      {[_event], state} = Antigravity.decode_stdout("done", state)

      assert {[event], next_state} =
               Antigravity.handle_exit(ProcessExit.from_reason({:exit_status, 0}), state)

      assert event.kind == :result
      assert %Payload.Result{status: :completed} = event.payload
      assert next_state.result_emitted?
    end

    test "emits a process-exit error on failed process exit" do
      state = Antigravity.init_parser_state(command: "agy-bin")

      assert {[event], _state} =
               Antigravity.handle_exit(
                 ProcessExit.from_reason({:exit_status, 2}, stderr: "authentication required"),
                 state
               )

      assert event.kind == :error
      assert %Payload.Error{code: "auth_error"} = event.payload
    end
  end

  describe "transport_options/1" do
    test "closes stdin on start for headless print runs" do
      assert Antigravity.transport_options([])[:close_stdin_on_start?] == true
      assert Antigravity.transport_options(startup_mode: :eager)[:startup_mode] == :eager
    end
  end

  describe "registry" do
    test "is available from the core default provider registry" do
      assert {:ok, Antigravity} = CliSubprocessCore.provider_profile(:antigravity)
    end
  end
end
