defmodule CliSubprocessCore.ProviderProfilesTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfiles.{Amp, Claude, Codex, Gemini}

  describe "build_invocation/1" do
    test "Claude builds the expected CLI invocation" do
      assert {:ok, %Command{} = command} =
               Claude.build_invocation(
                 command: "claude-bin",
                 prompt: "solve this",
                 cwd: "/tmp/claude",
                 env: %{"CLAUDE_ENV" => "1"},
                 model: "claude-3-7-sonnet",
                 max_turns: 5,
                 append_system_prompt: "stay terse",
                 permission_mode: :accept_edits,
                 include_thinking: true,
                 resume: "session-123"
               )

      assert command.command == "claude-bin"

      assert command.args == [
               "--output-format",
               "stream-json",
               "--verbose",
               "--print",
               "--resume",
               "session-123",
               "--model",
               "claude-3-7-sonnet",
               "--max-turns",
               "5",
               "--append-system-prompt",
               "stay terse",
               "--permission-mode",
               "acceptEdits",
               "--thinking",
               "solve this"
             ]

      assert command.cwd == "/tmp/claude"
      assert command.env == %{"CLAUDE_ENV" => "1"}
    end

    test "Codex builds the expected CLI invocation" do
      schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

      assert {:ok, %Command{} = command} =
               Codex.build_invocation(
                 command: "codex-bin",
                 prompt: "review this diff",
                 cwd: "/tmp/codex",
                 model: "gpt-5-codex",
                 reasoning_effort: :high,
                 output_schema: schema,
                 permission_mode: :yolo
               )

      assert command.command == "codex-bin"

      assert command.args == [
               "exec",
               "--json",
               "--model",
               "gpt-5-codex",
               "--reasoning-effort",
               "high",
               "--output-schema",
               Jason.encode!(schema),
               "--dangerously-bypass-approvals-and-sandbox",
               "review this diff"
             ]

      assert command.cwd == "/tmp/codex"
    end

    test "Gemini builds the expected CLI invocation" do
      assert {:ok, %Command{} = command} =
               Gemini.build_invocation(
                 command: "gemini-bin",
                 prompt: "hello",
                 cwd: "/tmp/gemini",
                 model: "gemini-2.5-pro",
                 sandbox: true,
                 extensions: ["fs", "git"],
                 permission_mode: :plan
               )

      assert command.command == "gemini-bin"

      assert command.args == [
               "--prompt",
               "hello",
               "--output-format",
               "stream-json",
               "--model",
               "gemini-2.5-pro",
               "--sandbox",
               "--extensions",
               "fs,git",
               "--approval-mode",
               "plan"
             ]

      assert command.cwd == "/tmp/gemini"
    end

    test "Amp builds the expected CLI invocation" do
      permissions = %{"edit" => true}
      mcp_config = %{"servers" => [%{"name" => "demo"}]}

      assert {:ok, %Command{} = command} =
               Amp.build_invocation(
                 command: "amp-bin",
                 prompt: "ship it",
                 cwd: "/tmp/amp",
                 model: "amp-1",
                 mode: "chat",
                 max_turns: 2,
                 system_prompt: "do not waffle",
                 permissions: permissions,
                 mcp_config: mcp_config,
                 tools: ["bash", "edit"],
                 include_thinking: true,
                 permission_mode: :dangerously_allow_all
               )

      assert command.command == "amp-bin"

      assert command.args == [
               "run",
               "--output",
               "jsonl",
               "--model",
               "amp-1",
               "--mode",
               "chat",
               "--max-turns",
               "2",
               "--system-prompt",
               "do not waffle",
               "--permissions-json",
               Jason.encode!(permissions),
               "--mcp-config-json",
               Jason.encode!(mcp_config),
               "--tool",
               "bash",
               "--tool",
               "edit",
               "--thinking",
               "--dangerously-allow-all",
               "ship it"
             ]

      assert command.cwd == "/tmp/amp"
    end
  end

  describe "parser fixtures" do
    test "Claude decodes its JSONL fixture into normalized events" do
      events = decode_fixture(Claude, "claude")

      assert Enum.map(events, & &1.kind) == [
               :assistant_delta,
               :assistant_message,
               :thinking,
               :tool_use,
               :tool_result,
               :approval_requested,
               :approval_resolved,
               :cost_update,
               :result
             ]

      assert %Payload.AssistantDelta{content: "Hel"} = Enum.at(events, 0).payload
      assert Enum.at(events, 0).provider_session_id == "claude-session-1"

      assert %Payload.AssistantMessage{content: [%{"text" => "Hello", "type" => "text"}]} =
               Enum.at(events, 1).payload

      assert %Payload.Thinking{content: "Need tool", signature: "sig-1"} =
               Enum.at(events, 2).payload

      assert %Payload.ToolUse{
               tool_name: "shell",
               tool_call_id: "tool-1",
               input: %{"cmd" => "pwd"}
             } = Enum.at(events, 3).payload

      assert %Payload.ToolResult{tool_call_id: "tool-1", content: "/tmp", is_error: false} =
               Enum.at(events, 4).payload

      assert %Payload.ApprovalRequested{
               approval_id: "approval-1",
               subject: "shell",
               details: %{"tool_input" => %{"cmd" => "rm -rf /tmp/demo"}}
             } = Enum.at(events, 5).payload

      assert %Payload.ApprovalResolved{
               approval_id: "approval-1",
               decision: :allow,
               reason: "approved"
             } = Enum.at(events, 6).payload

      assert %Payload.CostUpdate{
               input_tokens: 3,
               output_tokens: 5,
               total_tokens: 8,
               cost_usd: 0.12
             } = Enum.at(events, 7).payload

      assert %Payload.Result{
               status: :completed,
               stop_reason: "end_turn",
               output: %{duration_ms: 250, usage: %{input_tokens: 3, output_tokens: 5}}
             } = Enum.at(events, 8).payload

      assert [stderr] = decode_stderr(Claude, "claude warning")
      assert %Payload.Stderr{content: "claude warning"} = stderr.payload
    end

    test "Codex decodes its JSONL fixture into normalized events" do
      events = decode_fixture(Codex, "codex")

      assert Enum.map(events, & &1.kind) == [
               :assistant_delta,
               :assistant_message,
               :thinking,
               :tool_use,
               :tool_result,
               :result
             ]

      assert %Payload.AssistantDelta{content: "Hel"} = Enum.at(events, 0).payload
      assert Enum.at(events, 0).provider_session_id == "codex-session-1"

      assert %Payload.AssistantMessage{content: ["Hello"], model: "gpt-5-codex"} =
               Enum.at(events, 1).payload

      assert %Payload.Thinking{content: "Need tool", signature: "sig-2"} =
               Enum.at(events, 2).payload

      assert %Payload.ToolUse{
               tool_name: "shell",
               tool_call_id: "tool-2",
               input: %{"cmd" => "pwd"}
             } = Enum.at(events, 3).payload

      assert %Payload.ToolResult{tool_call_id: "tool-2", content: "/tmp", is_error: false} =
               Enum.at(events, 4).payload

      assert %Payload.Result{
               status: :completed,
               stop_reason: :end_turn,
               output: %{usage: %{input_tokens: 4, output_tokens: 6}}
             } = Enum.at(events, 5).payload

      assert [stderr] = decode_stderr(Codex, "codex warning")
      assert %Payload.Stderr{content: "codex warning"} = stderr.payload
    end

    test "Gemini decodes its JSONL fixture into normalized events" do
      events = decode_fixture(Gemini, "gemini")

      assert Enum.map(events, & &1.kind) == [
               :assistant_delta,
               :assistant_message,
               :user_message,
               :tool_use,
               :tool_result,
               :result
             ]

      assert %Payload.AssistantDelta{content: "Hel"} = Enum.at(events, 0).payload
      assert Enum.at(events, 0).provider_session_id == "gemini-session-1"

      assert %Payload.AssistantMessage{content: ["Hello"], model: "gemini-2.5-pro"} =
               Enum.at(events, 1).payload

      assert %Payload.UserMessage{content: ["Please help"]} = Enum.at(events, 2).payload

      assert %Payload.ToolUse{
               tool_name: "search",
               tool_call_id: "tool-3",
               input: %{"q" => "weather"}
             } = Enum.at(events, 3).payload

      assert %Payload.ToolResult{tool_call_id: "tool-3", content: "sunny", is_error: false} =
               Enum.at(events, 4).payload

      assert %Payload.Result{
               status: :completed,
               stop_reason: "completed",
               output: %{usage: %{input_tokens: 2, output_tokens: 4}}
             } = Enum.at(events, 5).payload

      assert [stderr] = decode_stderr(Gemini, "gemini warning")
      assert %Payload.Stderr{content: "gemini warning"} = stderr.payload
    end

    test "Amp decodes its JSONL fixture into normalized events" do
      events = decode_fixture(Amp, "amp")

      assert Enum.map(events, & &1.kind) == [
               :assistant_delta,
               :assistant_message,
               :tool_use,
               :tool_result,
               :approval_requested,
               :approval_resolved,
               :cost_update,
               :result
             ]

      assert %Payload.AssistantDelta{content: "Hel"} = Enum.at(events, 0).payload
      assert Enum.at(events, 0).provider_session_id == "amp-session-1"

      assert %Payload.AssistantMessage{content: ["Hello"], model: "amp-1"} =
               Enum.at(events, 1).payload

      assert %Payload.ToolUse{
               tool_name: "bash",
               tool_call_id: "tool-4",
               input: %{"cmd" => "pwd"}
             } = Enum.at(events, 2).payload

      assert %Payload.ToolResult{tool_call_id: "tool-4", content: "/tmp", is_error: false} =
               Enum.at(events, 3).payload

      assert %Payload.ApprovalRequested{
               approval_id: "approval-4",
               subject: "bash",
               details: %{"tool_input" => %{"cmd" => "rm -rf /tmp/demo"}}
             } = Enum.at(events, 4).payload

      assert %Payload.ApprovalResolved{
               approval_id: "approval-4",
               decision: :allow,
               reason: "approved"
             } = Enum.at(events, 5).payload

      assert %Payload.CostUpdate{
               input_tokens: 7,
               output_tokens: 9,
               total_tokens: 16,
               cost_usd: 0.21
             } = Enum.at(events, 6).payload

      assert %Payload.Result{
               status: :completed,
               stop_reason: "done",
               output: %{duration_ms: 300, usage: %{input_tokens: 7, output_tokens: 9}}
             } = Enum.at(events, 7).payload

      assert [stderr] = decode_stderr(Amp, "amp warning")
      assert %Payload.Stderr{content: "amp warning"} = stderr.payload
    end
  end

  defp decode_fixture(profile, fixture_name) do
    fixture_path =
      Path.expand("../fixtures/provider_profiles/#{fixture_name}.jsonl", __DIR__)

    {events, _state} =
      fixture_path
      |> File.stream!([], :line)
      |> Enum.map(&String.trim_trailing(&1, "\n"))
      |> Enum.reduce({[], profile.init_parser_state([])}, fn line, {acc, state} ->
        {decoded, next_state} = profile.decode_stdout(line, state)
        {acc ++ decoded, next_state}
      end)

    events
  end

  defp decode_stderr(profile, chunk) do
    {events, _state} = profile.decode_stderr(chunk, profile.init_parser_state([]))
    events
  end
end
