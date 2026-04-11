defmodule CliSubprocessCore.ProviderProfilesTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfiles.{Amp, Claude, Codex, Gemini}
  alias CliSubprocessCore.ProviderProfiles.Shared

  describe "build_invocation/1" do
    test "Claude builds the expected CLI invocation" do
      assert {:ok, %Command{} = command} =
               Claude.build_invocation(
                 command: "claude-bin",
                 prompt: "solve this",
                 cwd: "/tmp/claude",
                 env: %{"CLAUDE_ENV" => "1"},
                 model_payload: %{
                   provider: :claude,
                   requested_model: "haiku",
                   resolved_model: "llama3.2",
                   resolution_source: :explicit,
                   reasoning: nil,
                   reasoning_effort: nil,
                   normalized_reasoning_effort: nil,
                   model_family: "llama",
                   catalog_version: "2026-03-25",
                   visibility: :public,
                   provider_backend: :ollama,
                   model_source: :external,
                   env_overrides: %{
                     "ANTHROPIC_AUTH_TOKEN" => "ollama",
                     "ANTHROPIC_API_KEY" => "",
                     "ANTHROPIC_BASE_URL" => "http://127.0.0.1:11434"
                   },
                   settings_patch: %{},
                   backend_metadata: %{"external_model" => "llama3.2"},
                   errors: []
                 },
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
               "llama3.2",
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

      assert command.env == %{
               "CLAUDE_ENV" => "1",
               "ANTHROPIC_AUTH_TOKEN" => "ollama",
               "ANTHROPIC_API_KEY" => "",
               "ANTHROPIC_BASE_URL" => "http://127.0.0.1:11434"
             }
    end

    test "Codex builds the expected CLI invocation" do
      schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

      assert {:ok, %Command{} = command} =
               Codex.build_invocation(
                 command: "codex-bin",
                 prompt: "review this diff",
                 cwd: "/tmp/codex",
                 model_payload: %{
                   provider: :codex,
                   requested_model: "gpt-5-codex",
                   resolved_model: "gpt-5-codex",
                   resolution_source: :explicit,
                   reasoning: "high",
                   reasoning_effort: 1.2,
                   normalized_reasoning_effort: 1.2,
                   model_family: "gpt-5",
                   catalog_version: "2026-03-25",
                   visibility: :public,
                   errors: []
                 },
                 output_schema: schema,
                 skip_git_repo_check: true,
                 permission_mode: :yolo
               )

      assert command.command == "codex-bin"

      assert command.args == [
               "exec",
               "--json",
               "--model",
               "gpt-5-codex",
               "--config",
               ~s(model_reasoning_effort="high"),
               "--skip-git-repo-check",
               "--output-schema",
               Jason.encode!(schema),
               "--dangerously-bypass-approvals-and-sandbox",
               "review this diff"
             ]

      assert command.cwd == "/tmp/codex"
    end

    test "Codex builds the expected CLI invocation for the Ollama OSS backend" do
      assert {:ok, %Command{} = command} =
               Codex.build_invocation(
                 command: "codex-bin",
                 prompt: "review this diff",
                 cwd: "/tmp/codex",
                 model_payload: %{
                   provider: :codex,
                   requested_model: "gpt-oss:20b",
                   resolved_model: "gpt-oss:20b",
                   resolution_source: :explicit,
                   reasoning: "high",
                   reasoning_effort: nil,
                   normalized_reasoning_effort: nil,
                   model_family: "gpt-oss",
                   catalog_version: nil,
                   visibility: :public,
                   provider_backend: :oss,
                   model_source: :external,
                   env_overrides: %{},
                   settings_patch: %{},
                   backend_metadata: %{
                     "provider_backend" => "oss",
                     "oss_provider" => "ollama"
                   },
                   errors: []
                 }
               )

      assert command.command == "codex-bin"

      assert command.args == [
               "exec",
               "--json",
               "--config",
               ~s(model_provider="ollama"),
               "--config",
               ~s(model="gpt-oss:20b"),
               "--config",
               ~s(model_reasoning_effort="high"),
               "review this diff"
             ]
    end

    test "Gemini builds the expected CLI invocation" do
      assert {:ok, %Command{} = command} =
               Gemini.build_invocation(
                 command: "gemini-bin",
                 prompt: "hello",
                 cwd: "/tmp/gemini",
                 model_payload: %{
                   provider: :gemini,
                   requested_model: "gemini-2.5-pro",
                   resolved_model: "gemini-2.5-pro",
                   resolution_source: :explicit,
                   reasoning: nil,
                   reasoning_effort: nil,
                   normalized_reasoning_effort: nil,
                   model_family: "gemini",
                   catalog_version: "2026-03-25",
                   visibility: :public,
                   errors: []
                 },
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
      mcp_config = %{"servers" => [%{"name" => "demo"}]}

      assert {:ok, %Command{} = command} =
               Amp.build_invocation(
                 command: "amp-bin",
                 prompt: "ship it",
                 cwd: "/tmp/amp",
                 model_payload: %{
                   provider: :amp,
                   requested_model: "amp-1",
                   resolved_model: "amp-1",
                   resolution_source: :explicit,
                   reasoning: nil,
                   reasoning_effort: nil,
                   normalized_reasoning_effort: nil,
                   model_family: "amp",
                   catalog_version: "2026-03-25",
                   visibility: :public,
                   errors: []
                 },
                 mode: "smart",
                 mcp_config: mcp_config,
                 include_thinking: true,
                 permission_mode: :dangerously_allow_all
               )

      assert command.command == "amp-bin"

      assert command.args == [
               "--execute",
               "ship it",
               "--stream-json-thinking",
               "--no-ide",
               "--no-notifications",
               "--mode",
               "smart",
               "--mcp-config",
               Jason.encode!(mcp_config),
               "--dangerously-allow-all"
             ]

      assert command.cwd == "/tmp/amp"
    end

    test "uses resolved model payload when model option is not set" do
      assert {:ok, %Command{} = command} =
               Gemini.build_invocation(
                 command: "gemini-bin",
                 model_payload: %{
                   provider: :gemini,
                   requested_model: "legacy",
                   resolved_model: "gemini-2.5-pro",
                   resolution_source: :explicit,
                   reasoning: nil,
                   reasoning_effort: nil,
                   normalized_reasoning_effort: nil,
                   model_family: "gemini",
                   catalog_version: "2026-03-25",
                   visibility: :public,
                   errors: []
                 },
                 prompt: "hello",
                 cwd: "/tmp/gemini"
               )

      assert "--model" in command.args
      idx = Enum.find_index(command.args, &(&1 == "--model"))
      assert Enum.at(command.args, idx + 1) == "gemini-2.5-pro"
    end

    test "does not use raw model or reasoning options when payload is absent" do
      assert {:ok, %Command{} = command} =
               Codex.build_invocation(
                 command: "codex-bin",
                 prompt: "review this diff",
                 model: "gpt-5-codex",
                 reasoning_effort: :high
               )

      refute "--model" in command.args
      refute "--config" in command.args
    end

    test "does not emit --model when payload model is absent" do
      assert {:ok, %Command{} = command} =
               Amp.build_invocation(
                 command: "amp-bin",
                 model_payload: %{
                   provider: :amp,
                   requested_model: nil,
                   resolved_model: nil,
                   resolution_source: :default,
                   reasoning: nil,
                   reasoning_effort: nil,
                   normalized_reasoning_effort: nil,
                   model_family: "amp",
                   catalog_version: "2026-03-25",
                   visibility: :public,
                   errors: []
                 },
                 prompt: "ship it",
                 cwd: "/tmp/amp"
               )

      assert command.args == [
               "--execute",
               "ship it",
               "--stream-json",
               "--no-ide",
               "--no-notifications"
             ]
    end
  end

  describe "shared option helpers" do
    test "drops placeholder values in maybe_add_pair/3" do
      assert Shared.maybe_add_pair([], "--color", "nil") == []
      assert Shared.maybe_add_pair([], "--color", nil) == []
      assert Shared.maybe_add_pair([], "--color", "null") == []
      assert Shared.maybe_add_pair([], "--color", "") == []
    end

    test "drops placeholder values in maybe_add_repeat/3" do
      assert Shared.maybe_add_repeat([], "--tool", ["bash", "", "nil", "edit"]) == [
               "--tool",
               "bash",
               "--tool",
               "edit"
             ]
    end

    test "drops placeholder values in maybe_add_delimited/3" do
      assert Shared.maybe_add_delimited([], "--extensions", ["fs", "null", "git", ""]) == [
               "--extensions",
               "fs,git"
             ]
    end

    test "serializes scalar pair values safely" do
      assert Shared.maybe_add_pair([], "--threads", 3) == ["--threads", "3"]
      assert Shared.maybe_add_pair([], "--timeout", 3.5) == ["--timeout", "3.5"]
      assert Shared.maybe_add_pair([], "--auto", true) == ["--auto", "true"]
    end

    test "Codex closes stdin on start for one-shot exec runs" do
      assert Codex.transport_options([])[:close_stdin_on_start?] == true
      assert Codex.transport_options(startup_mode: :eager)[:startup_mode] == :eager
    end

    test "shared transport options preserve chunk-first line recovery controls" do
      opts =
        Shared.transport_options(
          max_buffer_size: 1_024,
          oversize_line_chunk_bytes: 128,
          max_recoverable_line_bytes: 16_384,
          oversize_line_mode: :chunk_then_fail,
          buffer_overflow_mode: :fatal,
          ignored: true
        )

      assert opts[:max_buffer_size] == 1_024
      assert opts[:oversize_line_chunk_bytes] == 128
      assert opts[:max_recoverable_line_bytes] == 16_384
      assert opts[:oversize_line_mode] == :chunk_then_fail
      assert opts[:buffer_overflow_mode] == :fatal
      refute Keyword.has_key?(opts, :ignored)
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

    test "Claude treats result frames with is_error=true as terminal auth errors" do
      state = Claude.init_parser_state([])

      raw =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "session_id" => "claude-auth-session",
          "result" =>
            "Your organization does not have access to Claude. Please login again or contact your administrator.",
          "is_error" => true
        })

      {[event], state} = Claude.decode_stdout(raw, state)

      assert event.kind == :error
      assert %Payload.Error{} = event.payload
      assert event.payload.code == "auth_error"
      assert event.payload.message =~ "organization does not have access"
      assert event.payload.metadata["recovery"]["class"] == "provider_auth_claim"
      assert event.payload.metadata["recovery"]["retryable?"] == true

      {events_after_exit, _state} =
        Claude.handle_exit(
          %ExecutionPlane.ProcessExit{status: :success, code: 0},
          state
        )

      assert events_after_exit == []
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

    test "Gemini preserves fatal provider severities on error events" do
      {events, _state} =
        Gemini.decode_stdout(
          ~s({"type":"error","severity":"fatal","message":"Authentication failed","timestamp":"2026-02-11T12:00:02.000Z"}),
          Gemini.init_parser_state([])
        )

      assert [%{kind: :error, payload: %Payload.Error{} = payload}] = events
      assert payload.severity == :fatal
      assert payload.code == "unknown"
      assert payload.metadata["severity"] == "fatal"
      assert payload.metadata["recovery"]["class"] == "provider_runtime_claim"
      assert payload.metadata["recovery"]["retryable?"] == true
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

    test "Amp decodes current execute stream JSON output" do
      lines = [
        ~s({"type":"system","subtype":"init","session_id":"amp-session-2"}),
        ~s({"type":"assistant","message":{"type":"message","role":"assistant","content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":13}},"session_id":"amp-session-2"}),
        ~s({"type":"result","subtype":"success","duration_ms":1074,"result":"OK","session_id":"amp-session-2"})
      ]

      {events, _state} =
        Enum.reduce(lines, {[], Amp.init_parser_state([])}, fn line, {acc, state} ->
          {decoded, next_state} = Amp.decode_stdout(line, state)
          {acc ++ decoded, next_state}
        end)

      assert Enum.map(events, & &1.kind) == [:raw, :assistant_message, :result]

      assert %Payload.AssistantMessage{content: [%{"type" => "text", "text" => "OK"}]} =
               Enum.at(events, 1).payload

      assert %Payload.Result{
               status: :completed,
               stop_reason: "success",
               output: %{duration_ms: 1074, usage: %{input_tokens: 10, output_tokens: 13}}
             } = Enum.at(events, 2).payload

      assert Enum.at(events, 2).provider_session_id == "amp-session-2"
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
