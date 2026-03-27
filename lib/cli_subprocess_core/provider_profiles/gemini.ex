defmodule CliSubprocessCore.ProviderProfiles.Gemini do
  @moduledoc """
  Built-in provider profile for the common Gemini CLI runtime.
  """

  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfiles.Shared

  @impl true
  def id, do: :gemini

  @impl true
  def capabilities do
    [:extensions, :interrupt, :sandbox, :streaming, :tools]
  end

  @impl true
  def build_invocation(opts) when is_list(opts) do
    with {:ok, prompt} <- Shared.required_binary_option(opts, :prompt),
         {:ok, command_spec} <- Shared.resolve_command_spec(opts, :gemini, "gemini", [:cli_path]) do
      args =
        ["--prompt", prompt, "--output-format", Keyword.get(opts, :output_format, "stream-json")] ++
          option_flags(opts)

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
    |> Shared.maybe_add_pair("--model", model_value(opts))
    |> Shared.maybe_add_flag("--sandbox", Keyword.get(opts, :sandbox, false))
    |> Shared.maybe_add_delimited("--extensions", Keyword.get(opts, :extensions, []))
    |> Kernel.++(permission_flags(opts))
  end

  defp permission_flags(opts) do
    case Shared.permission_mode(opts) do
      :auto_edit -> ["--approval-mode", "auto_edit"]
      :plan -> ["--approval-mode", "plan"]
      :yolo -> ["--yolo"]
      _ -> []
    end
  end

  defp model_value(opts) do
    Keyword.get(opts, :model_payload, %{})
    |> model_payload_value(:resolved_model)
  end

  defp model_payload_value(%{resolved_model: value}, _key), do: value

  defp model_payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp model_payload_value(_payload, _key), do: nil

  defp decode_event(raw, state) do
    case Shared.event_type(raw) do
      "message" ->
        message(raw, state)

      "tool_use" ->
        tool_use(raw, state)

      "tool_result" ->
        tool_result(raw, state)

      "result" ->
        result(raw, state)

      "error" ->
        error_event(raw, state)

      _other ->
        Shared.emit_single(:raw, Payload.Raw.new(stream: :stdout, content: raw), raw, state)
    end
  end

  defp message(raw, state) do
    case {Shared.fetch_any(raw, [:role, "role"]),
          Shared.truthy?(Shared.fetch_any(raw, [:delta, "delta"]))} do
      {"assistant", true} ->
        Shared.emit_single(
          :assistant_delta,
          Payload.AssistantDelta.new(content: Shared.fetch_any(raw, [:content, "content"]) || ""),
          raw,
          state
        )

      {"assistant", false} ->
        Shared.emit_single(
          :assistant_message,
          Payload.AssistantMessage.new(
            content: Shared.content_blocks(raw),
            model: Shared.fetch_any(raw, [:model, "model"])
          ),
          raw,
          state
        )

      {"user", _delta} ->
        Shared.emit_single(
          :user_message,
          Payload.UserMessage.new(content: Shared.content_blocks(raw)),
          raw,
          state
        )

      _other ->
        Shared.emit_single(:raw, Payload.Raw.new(stream: :stdout, content: raw), raw, state)
    end
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
        content: Shared.fetch_any(raw, [:content, "content", :output, "output"]),
        is_error: Shared.truthy?(Shared.fetch_any(raw, [:is_error, "is_error", :error, "error"]))
      ),
      raw,
      state
    )
  end

  defp result(raw, state) do
    stats = Shared.fetch_any(raw, [:stats, "stats"])
    stats = if is_map(stats), do: stats, else: %{}

    Shared.emit_single(
      :result,
      Payload.Result.new(
        status: :completed,
        stop_reason:
          Shared.fetch_any(raw, [:status, "status", :stop_reason, "stop_reason"]) || :unknown,
        output: %{
          usage: %{
            input_tokens: Shared.int_value(stats, [:input_tokens, "input_tokens"]),
            output_tokens: Shared.int_value(stats, [:output_tokens, "output_tokens"])
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
        message: Shared.fetch_any(raw, [:message, "message"]) || "Gemini parser error",
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
