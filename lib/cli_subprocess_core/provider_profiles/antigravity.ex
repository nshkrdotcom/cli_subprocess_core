defmodule CliSubprocessCore.ProviderProfiles.Antigravity do
  @moduledoc """
  Built-in provider profile for the Antigravity CLI (`agy`).

  `agy` is asked for `--output-format stream-json`, which emits one JSON object
  per line in an envelope keyed by its own event name:

      {"event":"init","conversation_id":"...","init":{...}}
      {"event":"step_update","step_update":{"step_index":3,"state":"ACTIVE",...}}
      {"event":"result","result":{"status":"SUCCESS","response":"...",...}}

  A run is a sequence of numbered steps, each of which goes `ACTIVE` then
  `DONE`. The step's `step_type` says what kind of work it is -- assistant text,
  a tool call, a checkpoint -- so the pair of states gives both the "this is
  starting" and "this finished" halves of a tool call.

  Plain text remains readable: a stdout line that is not JSON is emitted as an
  assistant delta, which is what this profile used to do with every line. That
  keeps an older `agy`, or an explicit `output_format: "text"`, working.
  """

  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderFeatures
  alias CliSubprocessCore.ProviderProfiles.Shared

  # `agy` names its tools after its own internals. Renderers key off the names
  # they already know from other providers, so a shell command is "bash" here
  # exactly as it is for Claude and Codex.
  @tool_names %{
    "run_command" => "bash",
    "command_status" => "bash",
    "send_command_input" => "bash",
    "write_to_file" => "Write",
    "replace_file_content" => "Edit",
    "multi_replace_file_content" => "Edit",
    "sed_file" => "Edit",
    "notebook_edit" => "Edit",
    "view_file" => "Read",
    "read_resource" => "Read",
    "list_dir" => "Glob",
    "find_by_name" => "Glob",
    "grep_search" => "Grep",
    "search_web" => "WebSearch",
    "read_url_content" => "WebFetch",
    "open_browser_url" => "WebFetch",
    "read_browser_page" => "WebFetch"
  }

  # Tool parameters are PascalCase. Renderers look for "command", "file_path",
  # "pattern" and "query", so translate rather than make every consumer learn
  # this provider's spelling.
  @param_keys %{
    "CommandLine" => "command",
    "TargetFile" => "file_path",
    "AbsolutePath" => "file_path",
    "File" => "file_path",
    "Query" => "query",
    "SearchTerm" => "pattern",
    "Pattern" => "pattern",
    "Url" => "url",
    "URL" => "url"
  }

  @impl true
  def id, do: :antigravity

  @impl true
  def capabilities do
    # Not `:tools`: that advertises accepting host-supplied tools, which `agy`
    # does not. It brings its own, and this profile now decodes their calls.
    [:sandbox, :streaming, :directory_mapping, :continuation]
  end

  @impl true
  def build_invocation(opts) when is_list(opts) do
    with :ok <-
           ProviderFeatures.require_option(
             id(),
             :structured_output,
             :output_schema,
             Keyword.get(opts, :output_schema)
           ),
         :ok <-
           ProviderFeatures.require_option(
             id(),
             :completion_only,
             :completion_only,
             Keyword.get(opts, :completion_only, false)
           ),
         {:ok, prompt} <- Shared.required_binary_option(opts, :prompt),
         {:ok, command_spec} <-
           Shared.resolve_command_spec(opts, :antigravity, "agy", [:cli_path]) do
      args =
        ["--print", prompt, "--output-format", output_format(opts)] ++ option_flags(opts)

      {:ok, Shared.command(command_spec, args, opts)}
    end
  end

  # Structured by default. A caller who asks for text still gets text, and the
  # decoder handles both, so neither choice can leave a run unreadable.
  defp output_format(opts) do
    case Keyword.get(opts, :output_format) do
      format when format in ["text", "json", "stream-json"] -> format
      format when format in [:text, :json, :stream_json] -> format |> to_string() |> dash()
      _ -> "stream-json"
    end
  end

  defp dash(format), do: String.replace(format, "_", "-")

  @impl true
  def init_parser_state(opts), do: Shared.init_parser_state(id(), opts)

  @impl true
  def decode_stdout(line, state) when is_binary(line) and is_map(state) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {[], state}

      # `decode_json_stdout` also lifts `conversation_id` into the parser state
      # as the provider session id, which is what makes `--continue` work.
      String.starts_with?(trimmed, "{") ->
        Shared.decode_json_stdout(line, state, &decode_event/2)

      # Text mode, a banner, or an older CLI. Treated as assistant text rather
      # than a parse error: a readable run beats a correct complaint.
      true ->
        Shared.emit_single(
          :assistant_delta,
          Payload.AssistantDelta.new(content: line),
          line,
          state
        )
    end
  end

  defp decode_event(raw, state) do
    event = Shared.fetch_any(raw, [:event, "event"])
    body = Shared.fetch_any(raw, [event, to_atom(event)]) || %{}

    case event do
      "step_update" when is_map(body) -> step_update(body, raw, state)
      "result" when is_map(body) -> result(body, raw, state)
      "error" -> error_event(body, raw, state)
      _ -> emit_raw(raw, state)
    end
  end

  defp to_atom(event) when is_binary(event) do
    String.to_existing_atom(event)
  rescue
    ArgumentError -> nil
  end

  defp to_atom(_event), do: nil

  # Every step reports ACTIVE then DONE. Which half carries meaning depends on
  # the kind of step, so dispatch on both.
  defp step_update(body, raw, state) do
    step_type = Shared.fetch_any(body, [:step_type, "step_type"])
    state_name = Shared.fetch_any(body, [:state, "state"])

    {events, state} = step_events(step_type, state_name, body, raw, state)
    {usage_events, state} = maybe_usage(body, raw, state)
    {events ++ usage_events, state}
  end

  defp step_events("agent_response", _state_name, body, raw, state) do
    case Shared.fetch_any(body, [:text_delta, "text_delta"]) do
      delta when is_binary(delta) and delta != "" ->
        Shared.emit_single(:assistant_delta, Payload.AssistantDelta.new(content: delta), raw, state)

      _ ->
        {[], state}
    end
  end

  defp step_events("tool", "ACTIVE", body, raw, state) do
    info = tool_info(body)

    Shared.emit_single(
      :tool_use,
      Payload.ToolUse.new(
        tool_name: tool_name(body),
        tool_call_id: step_id(body),
        input: tool_parameters(info)
      ),
      raw,
      state
    )
  end

  defp step_events("tool", "DONE", body, raw, state) do
    info = tool_info(body)
    output = Shared.fetch_any(info, [:output, "output"])

    Shared.emit_single(
      :tool_result,
      Payload.ToolResult.new(
        tool_call_id: step_id(body),
        content: output,
        is_error: tool_error?(body, output)
      ),
      raw,
      state
    )
  end

  # `user_input` echoes the prompt back. It is already on screen, and reprinting
  # a packet prompt would bury the run in its own instructions.
  defp step_events(_step_type, _state_name, _body, _raw, state), do: {[], state}

  # `usage` rides along on whichever step happens to report it, including
  # checkpoints that carry no other content.
  defp maybe_usage(body, raw, state) do
    case Shared.fetch_any(body, [:usage, "usage"]) do
      usage when is_map(usage) ->
        Shared.emit_single(
          :cost_update,
          Payload.CostUpdate.new(
            input_tokens: Shared.int_value(usage, [:input_tokens, "input_tokens"]),
            output_tokens: Shared.int_value(usage, [:output_tokens, "output_tokens"]),
            total_tokens: Shared.int_value(usage, [:total_tokens, "total_tokens"])
          ),
          raw,
          state
        )

      _ ->
        {[], state}
    end
  end

  defp result(body, raw, state) do
    status = Shared.fetch_any(body, [:status, "status"])
    usage = Shared.fetch_any(body, [:usage, "usage"]) || %{}
    success? = status in ["SUCCESS", "success", nil]

    Shared.emit_single(
      :result,
      Payload.Result.new(
        status: if(success?, do: :completed, else: :failed),
        stop_reason: if(success?, do: :end_turn, else: :error),
        output: %{
          response: Shared.fetch_any(body, [:response, "response"]),
          num_turns: Shared.fetch_any(body, [:num_turns, "num_turns"]),
          usage: %{
            input_tokens: Shared.int_value(usage, [:input_tokens, "input_tokens"]),
            output_tokens: Shared.int_value(usage, [:output_tokens, "output_tokens"]),
            total_tokens: Shared.int_value(usage, [:total_tokens, "total_tokens"])
          }
        }
      ),
      raw,
      state
    )
  end

  defp error_event(body, raw, state) do
    message =
      case body do
        body when is_map(body) -> Shared.fetch_any(body, [:message, "message"])
        body when is_binary(body) -> body
        _ -> nil
      end

    Shared.emit_single(
      :error,
      Shared.error_payload(id(),
        code: "provider_error",
        message: message || "Antigravity reported an error",
        metadata: Shared.normalize_map(raw)
      ),
      raw,
      state
    )
  end

  defp emit_raw(raw, state) do
    Shared.emit_single(:raw, Payload.Raw.new(stream: :stdout, content: raw), raw, state)
  end

  defp tool_info(body) do
    case Shared.fetch_any(body, [:tool_info, "tool_info"]) do
      info when is_map(info) -> info
      _ -> %{}
    end
  end

  # ACTIVE and DONE share a step_index, which is what pairs a call with its
  # result.
  defp step_id(body) do
    case Shared.fetch_any(body, [:step_index, "step_index"]) do
      index when is_integer(index) -> "step_#{index}"
      index when is_binary(index) -> index
      _ -> nil
    end
  end

  defp tool_name(body) do
    raw_name =
      Shared.fetch_any(body, [:tool_name, "tool_name"]) ||
        body |> tool_info() |> Shared.fetch_any([:name, "name"])

    case raw_name do
      name when is_binary(name) -> Map.get(@tool_names, name, name)
      _ -> "tool"
    end
  end

  defp tool_parameters(info) do
    case Shared.fetch_any(info, [:parameters, "parameters"]) do
      params when is_map(params) ->
        Map.new(params, fn {key, value} ->
          {Map.get(@param_keys, to_string(key), to_string(key)), value}
        end)

      _ ->
        %{}
    end
  end

  # Only an explicit status counts. `agy` reports a failed shell command as
  # ordinary tool output, and sniffing that text for error-looking strings would
  # mark a successful `grep "No such file or directory"` as a failure.
  defp tool_error?(body, _output) do
    Shared.fetch_any(body, [:status, "status"]) in ["ERROR", "FAILED", "error", "failed"]
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

  defp option_flags(opts) do
    []
    |> Shared.maybe_add_flag("--sandbox", Keyword.get(opts, :sandbox, false))
    |> Shared.maybe_add_flag(
      "--dangerously-skip-permissions",
      Keyword.get(opts, :dangerously_skip_permissions, false)
    )
    |> Shared.maybe_add_pair("--conversation", Keyword.get(opts, :conversation))
    |> Shared.maybe_add_flag("--continue", Keyword.get(opts, :continue, false))
    |> Shared.maybe_add_pair("--print-timeout", Keyword.get(opts, :print_timeout))
    |> Shared.maybe_add_pair("--log-file", Keyword.get(opts, :log_file))
    |> add_dirs(Keyword.get(opts, :add_dirs, []))
    |> Kernel.++(permission_flags(opts))
  end

  defp permission_flags(opts) do
    mode = Shared.permission_mode(opts)

    if Keyword.get(opts, :dangerously_skip_permissions, false) and bypass_mode?(mode) do
      []
    else
      ProviderFeatures.permission_args(id(), mode)
    end
  end

  defp bypass_mode?(mode) when mode in [:bypass, :dangerously_skip_permissions], do: true

  defp bypass_mode?(mode) when mode in ["bypass", "dangerously_skip_permissions"], do: true

  defp bypass_mode?(_mode), do: false

  defp add_dirs(args, dirs) when is_list(dirs) do
    Enum.reduce(dirs, args, fn
      dir, acc when is_binary(dir) ->
        Shared.maybe_add_pair(acc, "--add-dir", dir)

      _dir, acc ->
        acc
    end)
  end

  defp add_dirs(args, _dirs), do: args
end
