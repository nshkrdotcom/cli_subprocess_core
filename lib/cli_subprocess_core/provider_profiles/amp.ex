defmodule CliSubprocessCore.ProviderProfiles.Amp do
  @moduledoc """
  Built-in provider profile for the common Amp CLI runtime.
  """

  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfiles.Shared

  @event_handlers %{
    "approval_requested" => :approval_requested,
    "approval_resolved" => :approval_resolved,
    "assistant" => :assistant_message,
    "assistant_delta" => :assistant_delta,
    "cost_update" => :cost_update,
    "error" => :error_event,
    "error_occurred" => :error_event,
    "message_received" => :assistant_message,
    "message_streamed" => :assistant_delta,
    "result" => :result,
    "run_cancelled" => :cancelled,
    "run_completed" => :result,
    "run_failed" => :error_event,
    "token_usage_updated" => :cost_update,
    "tool_call_completed" => {:tool_result, false},
    "tool_call_failed" => {:tool_result, true},
    "tool_call_started" => :tool_use,
    "tool_result" => {:tool_result, nil},
    "tool_use" => :tool_use
  }

  @impl true
  def id, do: :amp

  @impl true
  def capabilities do
    [:approval, :interrupt, :mcp, :streaming, :thinking, :tools]
  end

  @impl true
  def build_invocation(opts) when is_list(opts) do
    with {:ok, prompt} <- Shared.required_binary_option(opts, :prompt) do
      args = ["--execute", prompt] ++ output_flags(opts) ++ option_flags(opts)
      {:ok, Shared.command(Shared.resolve_command(opts, "amp"), args, opts)}
    end
  rescue
    error ->
      {:error, {:invalid_option_encoding, Exception.message(error)}}
  end

  @impl true
  def init_parser_state(opts) do
    Shared.init_parser_state(id(), opts)
    |> Map.merge(%{amp_last_stop_reason: nil, amp_last_usage: %{}})
  end

  @impl true
  def decode_stdout(line, state) when is_binary(line) and is_map(state) do
    Shared.decode_json_stdout(line, state, &decode_event/2)
  end

  @impl true
  def decode_stderr(chunk, state), do: Shared.decode_stderr(chunk, state)

  @impl true
  def handle_exit(reason, state), do: Shared.handle_exit(reason, state)

  @impl true
  def transport_options(opts) do
    Shared.transport_options(opts)
    |> Keyword.put(:close_stdin_on_start?, true)
  end

  defp output_flags(opts) do
    if Keyword.get(opts, :include_thinking, false) do
      ["--stream-json-thinking"]
    else
      ["--stream-json"]
    end
  end

  defp option_flags(opts) do
    ["--no-ide", "--no-notifications"]
    |> Shared.maybe_add_pair("--mode", Keyword.get(opts, :mode))
    |> Shared.maybe_add_json_pair("--mcp-config", Keyword.get(opts, :mcp_config))
    |> Kernel.++(permission_flags(opts))
  end

  defp permission_flags(opts) do
    case Shared.permission_mode(opts) do
      :dangerously_allow_all ->
        ["--dangerously-allow-all"]

      _ ->
        []
    end
  end

  defp decode_event(raw, state) do
    @event_handlers
    |> Map.get(Shared.event_type(raw))
    |> dispatch_event(raw, state)
  end

  defp dispatch_event(:assistant_delta, raw, state), do: assistant_delta(raw, state)
  defp dispatch_event(:assistant_message, raw, state), do: assistant_message(raw, state)
  defp dispatch_event(:tool_use, raw, state), do: tool_use(raw, state)

  defp dispatch_event({:tool_result, forced_error}, raw, state),
    do: tool_result(raw, state, forced_error)

  defp dispatch_event(:cost_update, raw, state), do: cost_update(raw, state)
  defp dispatch_event(:result, raw, state), do: result(raw, state)
  defp dispatch_event(:approval_requested, raw, state), do: approval_requested(raw, state)
  defp dispatch_event(:approval_resolved, raw, state), do: approval_resolved(raw, state)
  defp dispatch_event(:cancelled, raw, state), do: cancelled(raw, state)
  defp dispatch_event(:error_event, raw, state), do: error_event(raw, state)

  defp dispatch_event(nil, raw, state) do
    Shared.emit_single(:raw, Payload.Raw.new(stream: :stdout, content: raw), raw, state)
  end

  defp assistant_delta(raw, state) do
    Shared.emit_single(
      :assistant_delta,
      Payload.AssistantDelta.new(
        content:
          Shared.fetch_any(raw, [:delta, "delta", :text, "text", :content, "content"]) || ""
      ),
      raw,
      state
    )
  end

  defp assistant_message(raw, state) do
    message = assistant_message_source(raw)
    state = remember_assistant_result_fields(state, message)

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

  defp tool_use(raw, state) do
    Shared.emit_single(
      :tool_use,
      Payload.ToolUse.new(
        tool_name: Shared.fetch_any(raw, [:tool_name, "tool_name", :name, "name"]),
        tool_call_id:
          Shared.fetch_any(raw, [:tool_call_id, "tool_call_id", :tool_id, "tool_id", :id, "id"]),
        input: Shared.tool_input(raw)
      ),
      raw,
      state
    )
  end

  defp tool_result(raw, state, forced_error) do
    is_error =
      case forced_error do
        value when is_boolean(value) ->
          value

        _other ->
          Shared.truthy?(Shared.fetch_any(raw, [:is_error, "is_error", :error, "error"]))
      end

    Shared.emit_single(
      :tool_result,
      Payload.ToolResult.new(
        tool_call_id:
          Shared.fetch_any(raw, [:tool_call_id, "tool_call_id", :tool_id, "tool_id", :id, "id"]),
        content:
          Shared.fetch_any(raw, [
            :tool_output,
            "tool_output",
            :content,
            "content",
            :output,
            "output"
          ]),
        is_error: is_error
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
    usage = Shared.fetch_any(raw, [:token_usage, "token_usage", :usage, "usage", :stats, "stats"])
    usage = if is_map(usage), do: usage, else: raw

    input_tokens = Shared.int_value(usage, [:input_tokens, "input_tokens"])
    output_tokens = Shared.int_value(usage, [:output_tokens, "output_tokens"])

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
    usage = Shared.fetch_any(raw, [:token_usage, "token_usage", :usage, "usage", :stats, "stats"])
    usage = if is_map(usage), do: usage, else: Map.get(state, :amp_last_usage, %{})
    stop_reason = result_stop_reason(raw, state)

    Shared.emit_single(
      :result,
      Payload.Result.new(
        status: :completed,
        stop_reason: stop_reason,
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

  defp cancelled(raw, state) do
    Shared.emit_single(
      :error,
      Payload.Error.new(message: "Run cancelled", code: "user_cancelled", severity: :warning),
      raw,
      state
    )
  end

  defp error_event(raw, state) do
    payload =
      Payload.Error.new(
        message:
          Shared.fetch_any(raw, [:error_message, "error_message", :message, "message"]) ||
            "Amp parser error",
        code:
          raw
          |> Shared.fetch_any([
            :error_code,
            "error_code",
            :error_kind,
            "error_kind",
            :kind,
            "kind"
          ])
          |> Shared.normalize_kind()
          |> Atom.to_string(),
        severity: Shared.normalize_severity(Shared.fetch_any(raw, [:severity, "severity"])),
        metadata: Shared.normalize_map(raw)
      )

    Shared.emit_single(:error, payload, raw, state)
  end

  defp assistant_message_source(raw) do
    case Shared.fetch_any(raw, [:message, "message"]) do
      message when is_map(message) -> message
      _ -> raw
    end
  end

  defp remember_assistant_result_fields(state, message) when is_map(message) do
    usage =
      case Shared.fetch_any(message, [:usage, "usage", :token_usage, "token_usage"]) do
        value when is_map(value) -> value
        _ -> %{}
      end

    state
    |> Map.put(:amp_last_stop_reason, Shared.fetch_any(message, [:stop_reason, "stop_reason"]))
    |> Map.put(:amp_last_usage, usage)
  end

  defp result_stop_reason(raw, state) do
    Shared.fetch_any(raw, [
      :stop_reason,
      "stop_reason",
      :status,
      "status",
      :reason,
      "reason",
      :subtype,
      "subtype"
    ]) || Map.get(state, :amp_last_stop_reason) || :unknown
  end
end
