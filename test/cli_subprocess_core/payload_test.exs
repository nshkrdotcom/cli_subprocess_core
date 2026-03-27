defmodule CliSubprocessCore.PayloadTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Payload

  @payload_cases [
    {Payload.RunStarted,
     [provider_session_id: "provider-session", command: "codex", args: ["exec"]]},
    {Payload.AssistantDelta, [content: "partial"]},
    {Payload.AssistantMessage, [content: ["complete"], model: "gpt-5.4"]},
    {Payload.UserMessage, [content: ["input"]]},
    {Payload.Thinking, [content: "reasoning"]},
    {Payload.ToolUse, [tool_name: "shell", tool_call_id: "tool-1", input: %{"cmd" => "pwd"}]},
    {Payload.ToolResult, [tool_call_id: "tool-1", content: "ok"]},
    {Payload.ApprovalRequested,
     [approval_id: "approval-1", subject: "shell", details: %{"cmd" => "rm"}]},
    {Payload.ApprovalResolved, [approval_id: "approval-1", decision: :allow]},
    {Payload.CostUpdate, [input_tokens: 1, output_tokens: 2, total_tokens: 3, cost_usd: 0.02]},
    {Payload.Result, [status: :completed, stop_reason: :completed, output: %{text: "done"}]},
    {Payload.Error, [message: "boom", code: "runtime_error", severity: :error]},
    {Payload.Stderr, [content: "stderr chunk"]},
    {Payload.Raw, [stream: :stdout, content: "{\"raw\":true}"]}
  ]

  for {module, attrs} <- @payload_cases do
    test "#{inspect(module)}.new/1 builds the payload struct" do
      {module, attrs} = unquote(Macro.escape({module, attrs}))
      payload = module.new(attrs)

      assert %^module{} = payload
      assert Map.get(payload, :metadata) == %{}
    end

    test "#{inspect(module)}.parse/1 preserves unknown fields for forward-compatible boundaries" do
      {module, attrs} = unquote(Macro.escape({module, attrs}))

      assert {:ok, payload} =
               attrs
               |> Enum.into(%{})
               |> Map.put("wire_field", "kept")
               |> module.parse()

      assert %^module{extra: %{"wire_field" => "kept"}} = payload
      assert module.to_map(payload)["wire_field"] == "kept"
    end
  end

  test "Payload.Error accepts fatal severity for transport-terminal failures" do
    assert %Payload.Error{severity: :fatal} =
             Payload.Error.new(message: "boom", code: "auth_error", severity: :fatal)

    assert {:ok, %Payload.Error{severity: :fatal}} =
             Payload.Error.parse(%{"message" => "boom", "severity" => "fatal"})
  end
end
