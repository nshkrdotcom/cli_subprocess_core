defmodule CliSubprocessCore.ProviderProfiles.Claude do
  @moduledoc """
  Built-in provider profile for the common Claude CLI runtime.
  """

  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfiles.Shared

  @required_flags ["--output-format", "stream-json", "--verbose", "--print"]
  @event_handlers %{
    "assistant" => :assistant_message,
    "assistant_delta" => :assistant_delta,
    "assistant_message" => :assistant_message,
    "approval_requested" => :approval_requested,
    "approval_resolved" => :approval_resolved,
    "cost_update" => :cost_update,
    "error" => :error_event,
    "result" => :result,
    "text_delta" => :assistant_delta,
    "thinking" => :thinking,
    "tool_result" => :tool_result,
    "tool_use" => :tool_use
  }

  @impl true
  def id, do: :claude

  @impl true
  def capabilities do
    [:approval, :cost, :interrupt, :resume, :streaming, :thinking, :tools]
  end

  @impl true
  def build_invocation(opts) when is_list(opts) do
    with {:ok, prompt} <- Shared.required_binary_option(opts, :prompt) do
      args =
        @required_flags ++
          resume_args(Keyword.get(opts, :resume)) ++
          option_flags(opts) ++
          [prompt]

      {:ok,
       Shared.command(
         Shared.resolve_command(opts, "claude", [:path_to_claude_code_executable]),
         args,
         opts
       )}
    end
  end

  @impl true
  def init_parser_state(opts), do: Shared.init_parser_state(id(), opts)

  @impl true
  def decode_stdout(line, state) when is_binary(line) and is_map(state) do
    Shared.decode_json_stdout(line, state, &decode_event/2)
  end

  @impl true
  def decode_stderr(chunk, state), do: Shared.decode_stderr(chunk, state)

  @impl true
  def handle_exit(reason, state), do: Shared.handle_exit(reason, state)

  @impl true
  def transport_options(opts), do: Shared.transport_options(opts)

  defp option_flags(opts) do
    []
    |> Shared.maybe_add_pair("--model", Keyword.get(opts, :model))
    |> Shared.maybe_add_pair("--max-turns", Keyword.get(opts, :max_turns))
    |> Shared.maybe_add_pair("--append-system-prompt", Keyword.get(opts, :append_system_prompt))
    |> Shared.maybe_add_pair("--system-prompt", Keyword.get(opts, :system_prompt))
    |> Shared.maybe_add_pair("--permission-mode", permission_flag(opts))
    |> Shared.maybe_add_flag("--thinking", Keyword.get(opts, :include_thinking, false))
  end

  defp permission_flag(opts) do
    case Shared.permission_mode(opts) do
      :accept_edits -> "acceptEdits"
      :bypass_permissions -> "bypassPermissions"
      :delegate -> "delegate"
      :dont_ask -> "dontAsk"
      :plan -> "plan"
      value when is_atom(value) -> Atom.to_string(value)
      value when is_binary(value) -> value
      _ -> "default"
    end
  end

  defp resume_args(value) when is_binary(value) and value != "", do: ["--resume", value]
  defp resume_args(_value), do: []

  defp decode_event(raw, state) do
    @event_handlers
    |> Map.get(Shared.event_type(raw))
    |> dispatch_event(raw, state)
  end

  defp dispatch_event(:assistant_delta, raw, state), do: assistant_delta(raw, state)
  defp dispatch_event(:assistant_message, raw, state), do: assistant_message(raw, state)
  defp dispatch_event(:thinking, raw, state), do: thinking(raw, state)
  defp dispatch_event(:tool_use, raw, state), do: tool_use(raw, state)
  defp dispatch_event(:tool_result, raw, state), do: tool_result(raw, state)
  defp dispatch_event(:approval_requested, raw, state), do: approval_requested(raw, state)
  defp dispatch_event(:approval_resolved, raw, state), do: approval_resolved(raw, state)
  defp dispatch_event(:cost_update, raw, state), do: cost_update(raw, state)
  defp dispatch_event(:result, raw, state), do: result(raw, state)
  defp dispatch_event(:error_event, raw, state), do: error_event(raw, state)

  defp dispatch_event(nil, raw, state) do
    Shared.emit_single(:raw, Payload.Raw.new(stream: :stdout, content: raw), raw, state)
  end

  defp assistant_delta(raw, state) do
    Shared.emit_single(
      :assistant_delta,
      Payload.AssistantDelta.new(
        content: Shared.fetch_any(raw, [:delta, "delta", :text, "text"]) || ""
      ),
      raw,
      state
    )
  end

  defp assistant_message(raw, state) do
    message =
      case Shared.fetch_any(raw, [:message, "message"]) do
        value when is_map(value) -> value
        _ -> raw
      end

    Shared.emit_single(
      :assistant_message,
      Payload.AssistantMessage.new(
        content: Shared.content_blocks(message),
        model: Shared.fetch_any(message, [:model, "model"])
      ),
      raw,
      state
    )
  end

  defp thinking(raw, state) do
    Shared.emit_single(
      :thinking,
      Payload.Thinking.new(
        content: Shared.fetch_any(raw, [:thinking, "thinking", :text, "text"]) || "",
        signature: Shared.fetch_any(raw, [:signature, "signature"])
      ),
      raw,
      state
    )
  end

  defp tool_use(raw, state) do
    Shared.emit_single(
      :tool_use,
      Payload.ToolUse.new(
        tool_name: Shared.fetch_any(raw, [:tool_name, "tool_name", :name, "name"]),
        tool_call_id: Shared.fetch_any(raw, [:tool_id, "tool_id", :id, "id"]),
        input: Shared.tool_input(raw)
      ),
      raw,
      state
    )
  end

  defp tool_result(raw, state) do
    Shared.emit_single(
      :tool_result,
      Payload.ToolResult.new(
        tool_call_id: Shared.fetch_any(raw, [:tool_id, "tool_id", :id, "id"]),
        content: Shared.fetch_any(raw, [:content, "content"]),
        is_error: Shared.truthy?(Shared.fetch_any(raw, [:is_error, "is_error", :error, "error"]))
      ),
      raw,
      state
    )
  end

  defp approval_requested(raw, state) do
    Shared.emit_single(
      :approval_requested,
      Payload.ApprovalRequested.new(
        approval_id: Shared.fetch_any(raw, [:approval_id, "approval_id"]),
        subject: Shared.fetch_any(raw, [:tool_name, "tool_name", :name, "name"]),
        details: %{"tool_input" => Shared.tool_input(raw)}
      ),
      raw,
      state
    )
  end

  defp approval_resolved(raw, state) do
    decision =
      case Shared.fetch_any(raw, [:decision, "decision"]) do
        value when value in [:allow, "allow", "approved", true] -> :allow
        _ -> :deny
      end

    Shared.emit_single(
      :approval_resolved,
      Payload.ApprovalResolved.new(
        approval_id: Shared.fetch_any(raw, [:approval_id, "approval_id"]),
        decision: decision,
        reason: Shared.fetch_any(raw, [:reason, "reason"])
      ),
      raw,
      state
    )
  end

  defp cost_update(raw, state) do
    input_tokens = Shared.int_value(raw, [:input_tokens, "input_tokens"])
    output_tokens = Shared.int_value(raw, [:output_tokens, "output_tokens"])

    Shared.emit_single(
      :cost_update,
      Payload.CostUpdate.new(
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: input_tokens + output_tokens,
        cost_usd: Shared.float_value(raw, [:cost_usd, "cost_usd"])
      ),
      raw,
      state
    )
  end

  defp result(raw, state) do
    usage = Shared.fetch_any(raw, [:usage, "usage"])
    usage = if is_map(usage), do: usage, else: %{}

    Shared.emit_single(
      :result,
      Payload.Result.new(
        status: :completed,
        stop_reason:
          Shared.fetch_any(raw, [:stop_reason, "stop_reason", :reason, "reason"]) || :unknown,
        output: %{
          duration_ms: Shared.fetch_any(raw, [:duration_ms, "duration_ms"]),
          usage: %{
            input_tokens: Shared.int_value(usage, [:input_tokens, "input_tokens"]),
            output_tokens: Shared.int_value(usage, [:output_tokens, "output_tokens"])
          }
        }
      ),
      raw,
      state
    )
  end

  defp error_event(raw, state) do
    payload =
      Payload.Error.new(
        message: Shared.fetch_any(raw, [:message, "message"]) || "Claude parser error",
        code:
          raw
          |> Shared.fetch_any([:kind, "kind"])
          |> Shared.normalize_kind()
          |> Atom.to_string(),
        severity: Shared.normalize_severity(Shared.fetch_any(raw, [:severity, "severity"])),
        metadata: Shared.normalize_map(raw)
      )

    Shared.emit_single(:error, payload, raw, state)
  end
end
