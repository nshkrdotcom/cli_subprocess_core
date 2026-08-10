defmodule CliSubprocessCore.ProviderProfiles.AntigravityTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfiles.Antigravity
  alias ExecutionPlane.ProcessExit

  describe "build_invocation/1" do
    test "builds the basic agy print invocation" do
      assert {:ok, command} = Antigravity.build_invocation(command: "agy-bin", prompt: "hello")

      assert command.command == "agy-bin"
      assert command.args == ["--print", "hello", "--output-format", "stream-json"]
    end

    test "adds sandbox as a boolean flag" do
      assert {:ok, command} =
               Antigravity.build_invocation(command: "agy-bin", prompt: "hello", sandbox: true)

      assert command.args == ["--print", "hello", "--output-format", "stream-json", "--sandbox"]
    end

    test "adds dangerously skip permissions from the direct option" do
      assert {:ok, command} =
               Antigravity.build_invocation(
                 command: "agy-bin",
                 prompt: "hello",
                 dangerously_skip_permissions: true
               )

      assert command.args == ["--print", "hello", "--output-format", "stream-json", "--dangerously-skip-permissions"]
    end

    test "adds dangerously skip permissions from provider permission mode" do
      assert {:ok, command} =
               Antigravity.build_invocation(
                 command: "agy-bin",
                 prompt: "hello",
                 permission_mode: :bypass
               )

      assert command.args == ["--print", "hello", "--output-format", "stream-json", "--dangerously-skip-permissions"]
    end

    test "does not duplicate skip permissions when both aliases are set" do
      assert {:ok, command} =
               Antigravity.build_invocation(
                 command: "agy-bin",
                 prompt: "hello",
                 dangerously_skip_permissions: true,
                 permission_mode: :bypass
               )

      assert command.args == ["--print", "hello", "--output-format", "stream-json", "--dangerously-skip-permissions"]
    end

    test "adds one repeatable add-dir flag" do
      assert {:ok, command} =
               Antigravity.build_invocation(
                 command: "agy-bin",
                 prompt: "hello",
                 add_dirs: ["/workspace/one"]
               )

      assert command.args == ["--print", "hello", "--output-format", "stream-json", "--add-dir", "/workspace/one"]
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
               "--output-format",
               "stream-json",
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

      assert command.args == ["--print", "hello", "--output-format", "stream-json", "--conversation", "abc", "--continue"]
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
               "--output-format",
               "stream-json",
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

  # Every fixture below is a line `agy 1.1.11 --output-format stream-json`
  # actually wrote, captured from a live run rather than inferred from docs.
  describe "decode_stdout/2 (stream-json)" do
    defp state, do: Antigravity.init_parser_state(prompt: "hi", command: "agy")

    defp decode(line, st \\ nil), do: Antigravity.decode_stdout(line, st || state())

    defp step(body), do: ~s({"event":"step_update","step_update":#{body}})

    test "assistant text arrives as deltas" do
      line =
        step(
          ~s({"conversation_id":"c1","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"hello"})
        )

      assert {[event], _st} = decode(line)
      assert event.kind == :assistant_delta
      assert %Payload.AssistantDelta{content: "hello"} = event.payload
    end

    test "a shell command becomes a tool call under the name renderers know" do
      line =
        step(
          ~s({"step_index":3,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"cat probe.txt"}}})
        )

      assert {[event], _st} = decode(line)
      assert event.kind == :tool_use

      assert %Payload.ToolUse{
               tool_name: "bash",
               tool_call_id: "step_3",
               input: %{"command" => "cat probe.txt"}
             } = event.payload
    end

    test "the tool result pairs with its call by step index" do
      active =
        step(
          ~s({"step_index":3,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"cat probe.txt"}}})
        )

      done =
        step(
          ~s({"step_index":3,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"cat probe.txt"},"output":"hello from probe\\n"}})
        )

      assert {[use_event], st} = decode(active)
      assert {[result_event], _st} = decode(done, st)

      assert result_event.kind == :tool_result
      assert result_event.payload.tool_call_id == use_event.payload.tool_call_id
      assert result_event.payload.content =~ "hello from probe"
      refute result_event.payload.is_error
    end

    test "a file write is named for the file it writes" do
      line =
        step(
          ~s({"step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"write_to_file","tool_info":{"name":"write_to_file","parameters":{"TargetFile":"/tmp/made.txt"}}})
        )

      assert {[event], _st} = decode(line)

      assert %Payload.ToolUse{tool_name: "Write", input: %{"file_path" => "/tmp/made.txt"}} =
               event.payload
    end

    test "token usage rides along on whichever step reports it" do
      line =
        step(
          ~s({"step_index":5,"state":"DONE","step_type":"checkpoint","usage":{"input_tokens":96,"output_tokens":3,"total_tokens":99}})
        )

      assert {[event], _st} = decode(line)
      assert event.kind == :cost_update
      assert %Payload.CostUpdate{input_tokens: 96, output_tokens: 3, total_tokens: 99} = event.payload
    end

    test "the result terminates the run and carries its usage" do
      line =
        ~s({"event":"result","result":{"status":"SUCCESS","response":"hello\\n","num_turns":1,"usage":{"input_tokens":18627,"output_tokens":16,"total_tokens":18643}}})

      assert {[event], _st} = decode(line)
      assert event.kind == :result
      assert %Payload.Result{status: :completed, stop_reason: :end_turn} = event.payload
      assert event.payload.output.usage.total_tokens == 18643
    end

    test "a failed result is not reported as success" do
      line = ~s({"event":"result","result":{"status":"ERROR","response":"nope"}})

      assert {[event], _st} = decode(line)
      assert %Payload.Result{status: :failed, stop_reason: :error} = event.payload
    end

    test "the conversation id becomes the provider session id" do
      init =
        ~s({"event":"init","conversation_id":"8f3aea78-f03c-4123-823f-62bd03840c84","init":{"cwd":"/tmp","permission_mode":"always-proceed"}})

      assert {_events, st} = decode(init)

      assert {[event], _st} =
               decode(
                 step(~s({"step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"x"})),
                 st
               )

      assert event.provider_session_id == "8f3aea78-f03c-4123-823f-62bd03840c84"
    end



    test "an unrecognized event is kept as raw rather than dropped" do
      assert {[event], _st} = decode(~s({"event":"something_new","something_new":{"a":1}}))
      assert event.kind == :raw
    end
  end
end
