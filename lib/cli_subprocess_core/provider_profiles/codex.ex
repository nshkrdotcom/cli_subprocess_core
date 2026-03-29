defmodule CliSubprocessCore.ProviderProfiles.Codex do
  @moduledoc """
  Built-in provider profile for the common Codex CLI runtime.
  """

  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderFeatures
  alias CliSubprocessCore.ProviderProfiles.Shared

  @required_flags ["exec", "--json"]
  @event_handlers %{
    "assistant_delta" => :assistant_delta,
    "assistant_message" => :assistant_message,
    "error" => :error_event,
    "item.completed" => :completed_item,
    "response.output_text.delta" => :assistant_delta,
    "response.output_text.done" => :assistant_message,
    "result" => {:result, :unknown},
    "tool_call" => :tool_use,
    "tool_result" => :tool_result,
    "tool_use" => :tool_use,
    "turn.completed" => {:result, :end_turn}
  }

  @impl true
  def id, do: :codex

  @impl true
  def capabilities do
    [:interrupt, :plan, :reasoning, :streaming, :structured_output, :tools]
  end

  @impl true
  def build_invocation(opts) when is_list(opts) do
    with {:ok, prompt} <- Shared.required_binary_option(opts, :prompt),
         {:ok, command_spec} <- Shared.resolve_command_spec(opts, :codex, "codex") do
      args =
        @required_flags ++
          option_flags(opts) ++
          [prompt]

      {:ok, Shared.command(command_spec, args, opts)}
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
    |> Shared.maybe_add_flag("--oss", oss_enabled?(opts))
    |> Shared.maybe_add_pair("--local-provider", local_provider_value(opts))
    |> Shared.maybe_add_pair("--model", model_value(opts))
    |> Shared.maybe_add_flag("--skip-git-repo-check", Keyword.get(opts, :skip_git_repo_check))
    |> Shared.maybe_add_json_pair("--output-schema", Keyword.get(opts, :output_schema))
    |> Shared.maybe_add_repeat("--config", config_values(opts))
    |> Kernel.++(permission_flags(opts))
  end

  defp model_value(opts) do
    opts
    |> Keyword.get(:model_payload, %{})
    |> model_payload_value(:resolved_model)
  end

  defp reasoning_config_values(opts) do
    payload = Keyword.get(opts, :model_payload, %{})
    resolved_reasoning = model_payload_value(payload, :reasoning)
    normalized_reasoning = model_payload_value(payload, :normalized_reasoning_effort)

    cond do
      resolved_reasoning != nil -> [~s(model_reasoning_effort="#{resolved_reasoning}")]
      normalized_reasoning != nil -> [~s(model_reasoning_effort="#{normalized_reasoning}")]
      true -> []
    end
  end

  defp model_payload_value(value, key) when is_map(value) do
    Map.get(value, key, Map.get(value, Atom.to_string(key)))
  end

  defp model_payload_value(_payload, _key), do: nil

  defp model_payload_backend_metadata(opts) do
    opts
    |> Keyword.get(:model_payload, %{})
    |> model_payload_value(:backend_metadata)
    |> case do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp oss_enabled?(opts) do
    payload_backend =
      opts
      |> Keyword.get(:model_payload, %{})
      |> model_payload_value(:provider_backend)

    payload_backend in [:oss, "oss"]
  end

  defp local_provider_value(opts) do
    Map.get(model_payload_backend_metadata(opts), "oss_provider")
  end

  defp config_values(opts) do
    payload_values =
      model_payload_backend_metadata(opts)
      |> Map.get("config_values", [])
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    (reasoning_config_values(opts) ++ Keyword.get(opts, :config_values, []) ++ payload_values)
    |> Enum.uniq()
  end

  defp permission_flags(opts) do
    ProviderFeatures.permission_args(id(), Shared.permission_mode(opts))
  end

  defp decode_event(raw, state) do
    @event_handlers
    |> Map.get(Shared.event_type(raw))
    |> dispatch_event(raw, state)
  end

  defp dispatch_event(:assistant_delta, raw, state), do: assistant_delta(raw, state)
  defp dispatch_event(:assistant_message, raw, state), do: assistant_message(raw, state)
  defp dispatch_event(:completed_item, raw, state), do: completed_item(raw, state)
  defp dispatch_event(:tool_use, raw, state), do: tool_use(raw, state)
  defp dispatch_event(:tool_result, raw, state), do: tool_result(raw, state)
  defp dispatch_event(:error_event, raw, state), do: error_event(raw, state)

  defp dispatch_event({:result, default_stop_reason}, raw, state),
    do: result(raw, state, default_stop_reason)

  defp dispatch_event(nil, raw, state) do
    Shared.emit_single(:raw, Payload.Raw.new(stream: :stdout, content: raw), raw, state)
  end

  defp completed_item(raw, state) do
    case Shared.fetch_any(raw, [:item, "item"]) do
      item when is_map(item) ->
        case Shared.fetch_any(item, [:type, "type"]) do
          "agent_message" ->
            emit_completed_assistant_message(item, raw, state)

          "reasoning" ->
            emit_completed_thinking(item, raw, state)

          "tool_call" ->
            emit_completed_tool_use(item, raw, state)

          "tool_result" ->
            emit_completed_tool_result(item, raw, state)

          _ ->
            Shared.emit_single(:raw, Payload.Raw.new(stream: :stdout, content: raw), raw, state)
        end

      _other ->
        Shared.emit_single(:raw, Payload.Raw.new(stream: :stdout, content: raw), raw, state)
    end
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
    Shared.emit_single(
      :assistant_message,
      Payload.AssistantMessage.new(
        content: Shared.content_blocks(raw),
        model: Shared.fetch_any(raw, [:model, "model"])
      ),
      raw,
      state
    )
  end

  defp emit_completed_assistant_message(item, raw, state) do
    Shared.emit_single(
      :assistant_message,
      Payload.AssistantMessage.new(
        content: Shared.content_blocks(item),
        model: Shared.fetch_any(item, [:model, "model"])
      ),
      raw,
      state
    )
  end

  defp emit_completed_thinking(item, raw, state) do
    Shared.emit_single(
      :thinking,
      Payload.Thinking.new(
        content: Shared.fetch_any(item, [:thinking, "thinking", :text, "text"]) || "",
        signature: Shared.fetch_any(item, [:signature, "signature"])
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

  defp emit_completed_tool_use(item, raw, state) do
    Shared.emit_single(
      :tool_use,
      Payload.ToolUse.new(
        tool_name: Shared.fetch_any(item, [:tool_name, "tool_name", :name, "name"]),
        tool_call_id: Shared.fetch_any(item, [:tool_id, "tool_id", :id, "id"]),
        input: Shared.tool_input(item)
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

  defp emit_completed_tool_result(item, raw, state) do
    Shared.emit_single(
      :tool_result,
      Payload.ToolResult.new(
        tool_call_id: Shared.fetch_any(item, [:tool_id, "tool_id", :id, "id"]),
        content: Shared.fetch_any(item, [:content, "content"]),
        is_error: Shared.truthy?(Shared.fetch_any(item, [:is_error, "is_error", :error, "error"]))
      ),
      raw,
      state
    )
  end

  defp result(raw, state, default_stop_reason) do
    usage = Shared.fetch_any(raw, [:usage, "usage"])
    usage = if is_map(usage), do: usage, else: %{}

    Shared.emit_single(
      :result,
      Payload.Result.new(
        status: :completed,
        stop_reason:
          Shared.fetch_any(raw, [:stop_reason, "stop_reason", :reason, "reason"]) ||
            default_stop_reason,
        output: %{
          usage: %{
            input_tokens: Shared.int_value(usage, [:input_tokens, "input_tokens"]),
            output_tokens: Shared.int_value(usage, [:output_tokens, "output_tokens"]),
            total_tokens: Shared.int_value(usage, [:total_tokens, "total_tokens"])
          }
        },
        metadata: Shared.fetch_any(raw, [:metadata, "metadata"])
      ),
      raw,
      state
    )
  end

  defp error_event(raw, state) do
    payload =
      Payload.Error.new(
        code:
          raw
          |> Shared.fetch_any([:error_code, "error_code"])
          |> Shared.normalize_kind()
          |> Atom.to_string(),
        message:
          Shared.fetch_any(raw, [:message, "message", :error, "error"]) || "Codex parser error",
        metadata: Shared.normalize_map(raw)
      )

    Shared.emit_single(:error, payload, raw, state)
  end
end
