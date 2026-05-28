defmodule CliSubprocessCore.ProviderProfiles.Cursor do
  @moduledoc """
  Built-in provider profile for the Cursor Agent CLI (`agent`).

  Cursor uses headless `-p` execution with stream-json output. The prompt is a
  positional argument at the end of argv; there is no `--prompt` flag. When
  `:cwd` is supplied it is used both as the process working directory and as the
  Cursor `--workspace` argument.

  Governed launches follow the shared `GovernedAuthority` contract: command,
  cwd, env, and clear-env state come only from the materialized authority.
  `config_root` and `auth_root` are metadata; materializers must place any
  required Cursor paths into `authority.env`.
  """

  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderFeatures
  alias CliSubprocessCore.ProviderProfiles.Shared

  @impl true
  def id, do: :cursor

  @impl true
  def capabilities do
    [:interrupt, :mcp, :plan, :resume, :sandbox, :streaming, :tools]
  end

  @impl true
  def build_invocation(opts) when is_list(opts) do
    with {:ok, prompt} <- Shared.required_binary_option(opts, :prompt),
         {:ok, command_spec} <- Shared.resolve_command_spec(opts, :cursor, "agent", [:cli_path]) do
      args =
        required_flags(opts) ++
          option_flags(opts) ++
          permission_flags(opts) ++
          [prompt]

      {:ok, Shared.command(command_spec, args, opts)}
    end
  end

  @impl true
  def init_parser_state(opts) do
    Shared.init_parser_state(id(), opts)
    |> Map.merge(%{
      cursor_pending_tool_calls: %{},
      cursor_assistant_text: ""
    })
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

  defp required_flags(opts) do
    output_format = Keyword.get(opts, :output_format, "stream-json")

    ["-p", "--trust", "--output-format", output_format]
    |> maybe_add_stream_partial_output(opts)
  end

  defp maybe_add_stream_partial_output(args, opts) do
    if Keyword.get(opts, :stream_partial_output, true) do
      args ++ ["--stream-partial-output"]
    else
      args
    end
  end

  defp option_flags(opts) do
    []
    |> Shared.maybe_add_pair("--model", model_value(opts))
    |> Shared.maybe_add_pair("--workspace", Keyword.get(opts, :cwd))
    |> Shared.maybe_add_pair("--resume", Keyword.get(opts, :resume))
    |> Shared.maybe_add_flag("--continue", Keyword.get(opts, :continue, false))
    |> Shared.maybe_add_pair("--mode", mode_value(opts))
    |> Shared.maybe_add_pair("--sandbox", sandbox_value(opts))
    |> Shared.maybe_add_flag("--approve-mcps", Keyword.get(opts, :approve_mcps, false))
    |> maybe_add_worktree(Keyword.get(opts, :worktree))
    |> Shared.maybe_add_pair("--worktree-base", Keyword.get(opts, :worktree_base))
    |> Shared.maybe_add_flag(
      "--skip-worktree-setup",
      Keyword.get(opts, :skip_worktree_setup, false)
    )
    |> Shared.maybe_add_repeat("--plugin-dir", Keyword.get(opts, :plugin_dirs, []))
    |> add_headers(Keyword.get(opts, :headers, []))
  end

  defp permission_flags(opts) do
    ProviderFeatures.permission_args(id(), Shared.permission_mode(opts))
  end

  defp model_value(opts) do
    opts
    |> Keyword.get(:model_payload, %{})
    |> model_payload_value(:resolved_model)
    |> case do
      nil -> Keyword.get(opts, :model)
      value -> value
    end
  end

  defp model_payload_value(%{resolved_model: value}, _key), do: value

  defp model_payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp model_payload_value(_payload, _key), do: nil

  defp mode_value(opts) do
    case Keyword.get(opts, :mode) do
      value when value in [nil, :agent, "agent", :default, "default"] -> nil
      value -> value
    end
  end

  defp sandbox_value(opts) do
    case Keyword.get(opts, :sandbox) do
      true -> "enabled"
      false -> nil
      value -> value
    end
  end

  defp maybe_add_worktree(args, true), do: args ++ ["--worktree"]

  defp maybe_add_worktree(args, value) when is_binary(value),
    do: Shared.maybe_add_pair(args, "--worktree", value)

  defp maybe_add_worktree(args, _value), do: args

  defp add_headers(args, headers) when is_list(headers) do
    Enum.reduce(headers, args, fn
      {name, value}, acc when is_binary(name) and is_binary(value) ->
        acc ++ ["-H", "#{String.trim(name)}: #{String.trim(value)}"]

      value, acc when is_binary(value) ->
        Shared.maybe_add_pair(acc, "-H", value)

      _other, acc ->
        acc
    end)
  end

  defp add_headers(args, _headers), do: args

  defp decode_event(%{"type" => "system", "subtype" => "init"} = raw, state),
    do: raw_event(raw, state)

  defp decode_event(%{"type" => "user"} = raw, state), do: user_message(raw, state)

  defp decode_event(%{"type" => "thinking", "subtype" => "delta"} = raw, state),
    do: thinking_delta(raw, state)

  defp decode_event(%{"type" => "assistant"} = raw, state), do: assistant(raw, state)

  defp decode_event(%{"type" => "tool_call", "subtype" => "started"} = raw, state),
    do: tool_use(raw, state)

  defp decode_event(%{"type" => "tool_call", "subtype" => "completed"} = raw, state),
    do: tool_result(raw, state)

  defp decode_event(%{"type" => "connection", "subtype" => "reconnecting"} = raw, state),
    do: reconnecting(raw, state)

  defp decode_event(%{"type" => "retry"} = raw, state), do: raw_event(raw, state)
  defp decode_event(%{"type" => "result"} = raw, state), do: result(raw, state)
  defp decode_event(%{"type" => "error"} = raw, state), do: error_event(raw, state)
  defp decode_event(raw, state), do: raw_event(raw, state)

  defp raw_event(raw, state) do
    Shared.emit_single(:raw, Payload.Raw.new(stream: :stdout, content: raw), raw, state)
  end

  defp user_message(raw, state) do
    message = message_source(raw)

    Shared.emit_single(
      :user_message,
      Payload.UserMessage.new(content: Shared.content_blocks(message)),
      raw,
      state
    )
  end

  defp thinking_delta(raw, state) do
    Shared.emit_single(
      :thinking,
      Payload.Thinking.new(
        content: Shared.fetch_any(raw, [:text, "text", :delta, "delta"]) || "",
        metadata: %{subtype: subtype(raw)}
      ),
      raw,
      state
    )
  end

  defp assistant(raw, state) do
    message = message_source(raw)
    text = message_text(message)
    assistant(raw, message, text, state)
  end

  defp assistant(%{"timestamp_ms" => _timestamp_ms} = raw, _message, text, state) do
    state = append_cursor_assistant_text(state, text)

    Shared.emit_single(
      :assistant_delta,
      Payload.AssistantDelta.new(content: text, metadata: %{source: :cursor_partial}),
      raw,
      state
    )
  end

  defp assistant(raw, message, text, state) do
    case cursor_snapshot_suffix(state, text) do
      :not_snapshot ->
        emit_assistant_message(raw, message, state, %{})

      suffix ->
        emit_assistant_snapshot(raw, message, text, suffix, state)
    end
  end

  defp tool_use(raw, state) do
    tool_call_id = tool_call_id(raw)
    input = tool_input(raw)
    state = put_pending_tool(state, tool_call_id, input)

    Shared.emit_single(
      :tool_use,
      Payload.ToolUse.new(
        tool_name: tool_name(raw),
        tool_call_id: tool_call_id,
        input: input
      ),
      raw,
      state
    )
  end

  defp tool_result(raw, state) do
    tool_call_id = tool_call_id(raw)
    state = drop_pending_tool(state, tool_call_id)
    result = tool_call_result(raw)

    Shared.emit_single(
      :tool_result,
      Payload.ToolResult.new(
        tool_call_id: tool_call_id,
        content: tool_result_content(result),
        is_error: tool_result_error?(result),
        metadata: tool_result_metadata(result)
      ),
      raw,
      state
    )
  end

  defp reconnecting(raw, state) do
    {closed_events, state} = close_pending_tools(state, raw, :connection_reconnecting)
    {raw_events, state} = raw_event(raw, state)
    {closed_events ++ raw_events, state}
  end

  defp result(raw, state) do
    usage = result_usage(raw)
    status = result_status(Shared.fetch_any(raw, [:is_error, "is_error"]))

    Shared.emit_single(
      :result,
      Payload.Result.new(
        status: status,
        stop_reason: subtype(raw) || Shared.fetch_any(raw, [:status, "status"]) || :unknown,
        output: %{
          duration_ms: Shared.int_value(raw, [:duration_ms, "duration_ms"]),
          result: Shared.fetch_any(raw, [:result, "result"]),
          usage: %{
            input_tokens:
              Shared.int_value(usage, [:inputTokens, "inputTokens", :input_tokens, "input_tokens"]),
            output_tokens:
              Shared.int_value(usage, [
                :outputTokens,
                "outputTokens",
                :output_tokens,
                "output_tokens"
              ])
          }
        }
      ),
      raw,
      state
    )
  end

  defp error_event(raw, state) do
    payload =
      Shared.error_payload(:cursor,
        message:
          Shared.fetch_any(raw, [:message, "message", :error, "error"]) || "Cursor parser error",
        code:
          raw
          |> Shared.fetch_any([:kind, "kind", :code, "code"])
          |> Shared.normalize_kind()
          |> Atom.to_string(),
        severity: Shared.normalize_severity(Shared.fetch_any(raw, [:severity, "severity"])),
        metadata: Shared.normalize_map(raw)
      )

    Shared.emit_single(:error, payload, raw, state)
  end

  defp result_usage(raw) do
    case Shared.fetch_any(raw, [:usage, "usage"]) do
      usage when is_map(usage) -> usage
      _other -> %{}
    end
  end

  defp result_status(value) when value in [true, "true", 1, "1", "yes", "on"], do: :error
  defp result_status(_value), do: :completed

  defp close_pending_tools(state, raw, reason) do
    pending = Map.get(state, :cursor_pending_tool_calls, %{})
    state = Map.put(state, :cursor_pending_tool_calls, %{})

    Enum.map_reduce(pending, state, fn {tool_call_id, input}, acc ->
      Shared.emit_event(
        :tool_result,
        Payload.ToolResult.new(
          tool_call_id: tool_call_id,
          content: nil,
          is_error: true,
          metadata: %{reason: reason, input: input}
        ),
        raw,
        acc
      )
    end)
  end

  defp put_pending_tool(state, nil, _input), do: state

  defp put_pending_tool(state, tool_call_id, input) do
    pending = Map.get(state, :cursor_pending_tool_calls, %{})
    Map.put(state, :cursor_pending_tool_calls, Map.put(pending, tool_call_id, input))
  end

  defp drop_pending_tool(state, nil), do: state

  defp drop_pending_tool(state, tool_call_id) do
    pending =
      state
      |> Map.get(:cursor_pending_tool_calls, %{})
      |> Map.delete(tool_call_id)

    Map.put(state, :cursor_pending_tool_calls, pending)
  end

  defp subtype(raw) do
    Shared.fetch_any(raw, [:subtype, "subtype", :status, "status"])
  end

  defp message_source(raw) do
    case Shared.fetch_any(raw, [:message, "message"]) do
      message when is_map(message) -> message
      _other -> raw
    end
  end

  defp message_text(message) when is_map(message) do
    message
    |> Shared.content_blocks()
    |> Enum.map_join("", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{type: "text", text: text} when is_binary(text) -> text
      text when is_binary(text) -> text
      other -> to_string(other)
    end)
  end

  defp append_cursor_assistant_text(state, text) when is_binary(text) do
    Map.update(state, :cursor_assistant_text, text, &(&1 <> text))
  end

  defp cursor_snapshot_suffix(state, text) when is_binary(text) do
    accumulated = Map.get(state, :cursor_assistant_text, "")

    if accumulated != "" and String.starts_with?(text, accumulated) do
      String.replace_prefix(text, accumulated, "")
    else
      :not_snapshot
    end
  end

  defp emit_assistant_snapshot(raw, message, text, suffix, state) do
    state = Map.put(state, :cursor_assistant_text, text)

    if suffix == "" do
      emit_assistant_message(raw, message, state, %{source: :cursor_final_snapshot})
    else
      {delta, state} =
        Shared.emit_event(
          :assistant_delta,
          Payload.AssistantDelta.new(
            content: suffix,
            metadata: %{source: :cursor_snapshot_suffix}
          ),
          raw,
          state
        )

      {message_events, state} =
        emit_assistant_message(raw, message, state, %{source: :cursor_final_snapshot})

      {[delta | message_events], state}
    end
  end

  defp emit_assistant_message(raw, message, state, metadata) do
    Shared.emit_single(
      :assistant_message,
      Payload.AssistantMessage.new(
        content: Shared.content_blocks(message),
        model: Shared.fetch_any(raw, [:model, "model"]),
        metadata: metadata
      ),
      raw,
      state
    )
  end

  defp tool_name(raw) do
    case tool_call(raw) do
      %{"shellToolCall" => _shell_call} ->
        "shell"

      _tool_call ->
        Shared.fetch_any(raw, [:tool_name, "tool_name", :name, "name"])
    end
  end

  defp tool_call_id(raw) do
    Shared.fetch_any(raw, [:call_id, "call_id", :tool_call_id, "tool_call_id"]) ||
      raw
      |> tool_input()
      |> Shared.fetch_any([:toolCallId, "toolCallId", :tool_call_id, "tool_call_id"])
  end

  defp tool_input(raw) do
    raw
    |> tool_call()
    |> shell_tool_call()
    |> case do
      %{} = shell_call ->
        case Shared.fetch_any(shell_call, [:args, "args", :input, "input"]) do
          value when is_map(value) -> value
          _other -> %{}
        end

      _other ->
        Shared.tool_input(raw)
    end
  end

  defp tool_call_result(raw) do
    raw
    |> tool_call()
    |> shell_tool_call()
    |> case do
      %{} = shell_call ->
        case Shared.fetch_any(shell_call, [:result, "result"]) do
          value when is_map(value) -> value
          _other -> %{}
        end

      _other ->
        %{}
    end
  end

  defp tool_result_content(%{"success" => success}) when is_map(success) do
    Shared.fetch_any(success, [:stdout, "stdout", :interleavedOutput, "interleavedOutput"])
  end

  defp tool_result_content(%{"error" => error}) when is_map(error) do
    Shared.fetch_any(error, [:message, "message", :stderr, "stderr"])
  end

  defp tool_result_content(result) when is_map(result) do
    Shared.fetch_any(result, [:stdout, "stdout", :output, "output"])
  end

  defp tool_result_error?(%{"error" => _error}), do: true

  defp tool_result_error?(%{"success" => success}) when is_map(success) do
    Shared.int_value(success, [:exitCode, "exitCode", :exit_code, "exit_code"]) != 0
  end

  defp tool_result_error?(result) when is_map(result) do
    Shared.truthy?(Shared.fetch_any(result, [:is_error, "is_error", :error, "error"]))
  end

  defp tool_result_metadata(%{"success" => success}) when is_map(success),
    do: tool_result_metadata_from_source(success)

  defp tool_result_metadata(%{"error" => error}) when is_map(error),
    do: tool_result_metadata_from_source(error)

  defp tool_result_metadata(result) when is_map(result),
    do: tool_result_metadata_from_source(result)

  defp tool_result_metadata_from_source(source) do
    %{
      exit_code: Shared.fetch_any(source, [:exitCode, "exitCode", :exit_code, "exit_code"]),
      stderr: Shared.fetch_any(source, [:stderr, "stderr"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp tool_call(raw) when is_map(raw) do
    case Shared.fetch_any(raw, [:tool_call, "tool_call"]) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp shell_tool_call(tool_call) when is_map(tool_call) do
    case Shared.fetch_any(tool_call, [:shellToolCall, "shellToolCall"]) do
      value when is_map(value) -> value
      _other -> nil
    end
  end
end
