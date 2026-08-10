defmodule CliSubprocessCore.ProviderProfiles.CodexTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfiles.Codex

  # These fixtures are the shapes `codex exec --json` actually writes. The
  # decoder previously looked for `tool_call` and `tool_result` item types,
  # which the CLI has never emitted, so every tool call fell through to :raw
  # and no consumer could see that the model had done anything.

  defp state, do: Codex.init_parser_state(prompt: "hi", command: "codex")

  defp decode(event, state \\ nil) do
    Codex.decode_stdout(Jason.encode!(event), state || state())
  end

  defp item(type, fields), do: %{"type" => "item.completed", "item" => Map.put(fields, "type", type)}

  defp started(type, fields),
    do: %{"type" => "item.started", "item" => Map.put(fields, "type", type)}

  describe "item.started" do
    test "a shell command announces itself as a tool call" do
      assert {[event], _state} =
               decode(
                 started("command_execution", %{
                   "id" => "item_3",
                   "command" => ["bash", "-lc", "mix test"]
                 })
               )

      assert event.kind == :tool_use

      assert %Payload.ToolUse{
               tool_name: "Bash",
               tool_call_id: "item_3",
               input: %{"command" => "bash -lc mix test"}
             } = event.payload
    end

    test "a string command is passed through unjoined" do
      assert {[event], _state} =
               decode(started("command_execution", %{"id" => "i", "command" => "ls -la"}))

      assert %Payload.ToolUse{input: %{"command" => "ls -la"}} = event.payload
    end

    test "a file change is named for the path it edits" do
      assert {[event], _state} =
               decode(
                 started("file_change", %{
                   "id" => "item_9",
                   "changes" => [%{"path" => "/tmp/a.ex", "kind" => "update"}]
                 })
               )

      assert %Payload.ToolUse{tool_name: "Edit", input: %{"file_path" => "/tmp/a.ex"}} =
               event.payload
    end

    test "a web search carries its query" do
      assert {[event], _state} =
               decode(started("web_search", %{"id" => "w", "query" => "elixir genserver"}))

      assert %Payload.ToolUse{tool_name: "WebSearch", input: %{"query" => "elixir genserver"}} =
               event.payload
    end

    test "an MCP call is named server.tool" do
      assert {[event], _state} =
               decode(
                 started("mcp_tool_call", %{
                   "id" => "m",
                   "server" => "github",
                   "tool" => "list_issues",
                   "arguments" => %{"repo" => "x"}
                 })
               )

      assert %Payload.ToolUse{
               tool_name: "github.list_issues",
               input: %{"arguments" => %{"repo" => "x"}}
             } = event.payload
    end

    test "a todo list is a tool call" do
      assert {[event], _state} =
               decode(started("todo_list", %{"id" => "t", "items" => ["a", "b"]}))

      assert %Payload.ToolUse{tool_name: "TodoWrite", input: %{"items" => ["a", "b"]}} =
               event.payload
    end

    test "text items emit nothing, because they are emitted whole on completion" do
      assert {[], _state} = decode(started("agent_message", %{"id" => "a"}))
      assert {[], _state} = decode(started("reasoning", %{"id" => "r"}))
    end
  end

  describe "item.completed" do
    test "a successful command yields its aggregated output" do
      assert {[event], _state} =
               decode(
                 item("command_execution", %{
                   "id" => "item_3",
                   "command" => "echo hi",
                   "aggregated_output" => "hi\n",
                   "exit_code" => 0,
                   "status" => "completed"
                 })
               )

      assert event.kind == :tool_result

      assert %Payload.ToolResult{
               tool_call_id: "item_3",
               content: "hi\n",
               is_error: false
             } = event.payload
    end

    test "a non-zero exit code is an error" do
      assert {[event], _state} =
               decode(
                 item("command_execution", %{
                   "id" => "i",
                   "aggregated_output" => "boom",
                   "exit_code" => 2
                 })
               )

      assert %Payload.ToolResult{is_error: true} = event.payload
    end

    test "a failed status is an error even with no exit code" do
      for status <- ["failed", "errored", "interrupted", "not_found"] do
        assert {[event], _state} = decode(item("mcp_tool_call", %{"id" => "i", "status" => status}))
        assert %Payload.ToolResult{is_error: true} = event.payload
      end
    end

    test "the call and its result share one id, so a consumer can pair them" do
      {[use_event], state} =
        decode(started("command_execution", %{"id" => "item_7", "command" => "ls"}))

      {[result_event], _state} =
        decode(item("command_execution", %{"id" => "item_7", "exit_code" => 0}), state)

      assert use_event.payload.tool_call_id == result_event.payload.tool_call_id
    end

    test "an agent message is still assistant text" do
      assert {[event], _state} = decode(item("agent_message", %{"text" => "done"}))
      assert event.kind == :assistant_message
    end

    test "reasoning is still thinking" do
      assert {[event], _state} = decode(item("reasoning", %{"text" => "considering"}))
      assert event.kind == :thinking
    end

    test "an unknown item type is still raw, not dropped" do
      assert {[event], _state} = decode(item("some_future_item", %{"id" => "x"}))
      assert event.kind == :raw
    end
  end

  describe "provider session id" do
    # Codex announces its thread once, at the start. Every later event has to
    # keep carrying that id: resuming a thread reads it back, and a run that
    # forgets it can only resume a thread that does not exist.
    test "survives events that do not carry one" do
      {_events, state} = decode(%{"type" => "thread.started", "thread_id" => "thr_real"})
      {[event], _state} = decode(item("agent_message", %{"text" => "hi"}), state)

      assert event.provider_session_id == "thr_real"
    end
  end

  describe "turn.failed" do
    test "terminates the run with both an error and a result" do
      assert {events, _state} =
               decode(%{
                 "type" => "turn.failed",
                 "error" => %{"message" => "You've hit your usage limit."}
               })

      assert [error_event, result_event] = events
      assert error_event.kind == :error
      assert error_event.payload.message == "You've hit your usage limit."

      assert result_event.kind == :result
      assert %Payload.Result{status: :failed, stop_reason: :error} = result_event.payload
      assert result_event.payload.output == %{error: "You've hit your usage limit."}
    end

    test "falls back to a message when the error has no shape" do
      assert {[error_event, _result], _state} = decode(%{"type" => "turn.failed"})
      assert error_event.payload.message == "Codex turn failed"
    end
  end
end
