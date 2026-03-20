defmodule CliSubprocessCore.ProviderProfiles.Shared do
  @moduledoc false

  alias CliSubprocessCore.{Command, Event, Payload, ProcessExit}

  @transport_option_keys [
    :startup_mode,
    :task_supervisor,
    :headless_timeout_ms,
    :max_buffer_size,
    :max_stderr_buffer_size,
    :stderr_callback
  ]

  @type parser_state :: %{
          provider: atom(),
          emitted: non_neg_integer(),
          options: map(),
          provider_session_id: String.t() | nil,
          result_emitted?: boolean()
        }

  @spec init_parser_state(atom(), keyword()) :: parser_state()
  def init_parser_state(provider, opts) when is_atom(provider) and is_list(opts) do
    %{
      provider: provider,
      emitted: 0,
      options: Enum.into(opts, %{}),
      provider_session_id: nil,
      result_emitted?: false
    }
  end

  @spec required_binary_option(keyword(), atom()) :: {:ok, String.t()} | {:error, term()}
  def required_binary_option(opts, key) when is_list(opts) and is_atom(key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_option, key}}
    end
  end

  @spec resolve_command(keyword(), String.t(), [atom()]) :: String.t()
  def resolve_command(opts, default_command, extra_keys \\ [])
      when is_list(opts) and is_binary(default_command) and is_list(extra_keys) do
    keys = [:command, :executable] ++ extra_keys

    Enum.find_value(keys, default_command, fn key ->
      case Keyword.get(opts, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  @spec command(String.t(), [String.t()], keyword()) :: Command.t()
  def command(binary, args, opts)
      when is_binary(binary) and is_list(args) and is_list(opts) do
    Command.new(binary, args,
      cwd: Keyword.get(opts, :cwd),
      env: normalize_env(Keyword.get(opts, :env, %{}))
    )
  end

  @spec transport_options(keyword()) :: keyword()
  def transport_options(opts) when is_list(opts) do
    Keyword.take(opts, @transport_option_keys)
  end

  @spec permission_mode(keyword(), atom()) :: term()
  def permission_mode(opts, default \\ :default) when is_list(opts) do
    Keyword.get(opts, :provider_permission_mode, Keyword.get(opts, :permission_mode, default))
  end

  @spec maybe_add_pair([String.t()], String.t(), term()) :: [String.t()]
  def maybe_add_pair(args, _flag, nil), do: args
  def maybe_add_pair(args, flag, value), do: args ++ [flag, to_string(value)]

  @spec maybe_add_flag([String.t()], String.t(), term()) :: [String.t()]
  def maybe_add_flag(args, _flag, false), do: args
  def maybe_add_flag(args, _flag, nil), do: args
  def maybe_add_flag(args, flag, true), do: args ++ [flag]
  def maybe_add_flag(args, _flag, _other), do: args

  @spec maybe_add_json_pair([String.t()], String.t(), term()) :: [String.t()]
  def maybe_add_json_pair(args, _flag, nil), do: args

  def maybe_add_json_pair(args, flag, value) when is_map(value) or is_list(value) do
    args ++ [flag, Jason.encode!(value)]
  end

  def maybe_add_json_pair(args, _flag, _other), do: args

  @spec maybe_add_repeat([String.t()], String.t(), term()) :: [String.t()]
  def maybe_add_repeat(args, flag, values) when is_list(values) do
    Enum.reduce(values, args, fn
      value, acc when is_binary(value) and value != "" -> acc ++ [flag, value]
      _value, acc -> acc
    end)
  end

  def maybe_add_repeat(args, _flag, _values), do: args

  @spec maybe_add_delimited([String.t()], String.t(), term()) :: [String.t()]
  def maybe_add_delimited(args, flag, values) when is_list(values) do
    normalized =
      values
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join(",")

    if normalized == "" do
      args
    else
      args ++ [flag, normalized]
    end
  end

  def maybe_add_delimited(args, _flag, _values), do: args

  @spec decode_json_stdout(binary(), parser_state(), (map(), parser_state() ->
                                                        {[Event.t()], parser_state()})) ::
          {[Event.t()], parser_state()}
  def decode_json_stdout(line, state, fun)
      when is_binary(line) and is_map(state) and is_function(fun, 2) do
    case Jason.decode(line) do
      {:ok, raw} when is_map(raw) ->
        state = maybe_put_provider_session_id(state, extract_provider_session_id(raw))
        fun.(raw, state)

      {:ok, other} ->
        emit_single(:raw, Payload.Raw.new(stream: :stdout, content: other), other, state)

      {:error, error} ->
        emit_single(
          :error,
          Payload.Error.new(
            message: Exception.message(error),
            code: "parse_error",
            metadata: %{line: line}
          ),
          line,
          state
        )
    end
  end

  @spec decode_stderr(binary(), parser_state()) :: {[Event.t()], parser_state()}
  def decode_stderr(chunk, state) when is_binary(chunk) and is_map(state) do
    emit_single(:stderr, Payload.Stderr.new(content: chunk), chunk, state)
  end

  @spec handle_exit(term(), parser_state()) :: {[Event.t()], parser_state()}
  def handle_exit(reason, state) when is_map(state) do
    exit = ProcessExit.from_reason(reason)

    cond do
      ProcessExit.successful?(exit) and state.result_emitted? ->
        {[], state}

      ProcessExit.successful?(exit) ->
        payload =
          Payload.Result.new(
            status: :completed,
            stop_reason: exit.reason,
            output: %{code: exit.code, signal: exit.signal}
          )

        emit_single(:result, payload, %{exit: exit}, mark_result_emitted(state))

      true ->
        message =
          cond do
            is_integer(exit.code) -> "CLI exited with code #{exit.code}"
            exit.status == :signal -> "CLI terminated by signal #{inspect(exit.signal)}"
            true -> "CLI exited with #{inspect(exit.reason)}"
          end

        payload =
          Payload.Error.new(
            message: message,
            code: normalize_code(exit.reason),
            metadata: %{exit: Map.from_struct(exit)}
          )

        emit_single(:error, payload, %{exit: exit}, state)
    end
  end

  @spec event_type(map()) :: String.t()
  def event_type(raw) when is_map(raw) do
    raw
    |> fetch_any([:type, "type", :event, "event"])
    |> case do
      nil -> "unknown"
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end
  end

  @spec fetch_any(map(), [atom() | String.t()]) :: term()
  def fetch_any(raw, keys) when is_map(raw) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(raw, key) end)
  end

  @spec content_blocks(map()) :: [term()]
  def content_blocks(raw) when is_map(raw) do
    case fetch_any(raw, [:content, "content", :text, "text"]) do
      content when is_list(content) -> content
      content when is_binary(content) -> [content]
      nil -> []
      other -> [other]
    end
  end

  @spec tool_input(map()) :: map()
  def tool_input(raw) when is_map(raw) do
    case fetch_any(raw, [:tool_input, "tool_input", :input, "input"]) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  @spec normalize_map(map()) :: map()
  def normalize_map(raw) when is_map(raw) do
    Map.new(raw, fn
      {key, value} when is_atom(key) or is_binary(key) -> {key, value}
      {key, value} -> {to_string(key), value}
    end)
  end

  @spec normalize_severity(term()) :: :fatal | :warning | :error
  def normalize_severity(value) when value in [:fatal, "fatal"], do: :fatal
  def normalize_severity(value) when value in [:warning, "warning", "warn"], do: :warning
  def normalize_severity(_value), do: :error

  @spec normalize_kind(term()) :: atom()
  def normalize_kind(nil), do: :unknown
  def normalize_kind(kind) when is_atom(kind), do: kind

  def normalize_kind(kind) when is_binary(kind) do
    case String.downcase(kind) do
      "user_cancelled" -> :user_cancelled
      "cancelled" -> :user_cancelled
      "parse_error" -> :parse_error
      "timeout" -> :timeout
      "tool_failed" -> :tool_failed
      "approval_denied" -> :approval_denied
      "rate_limit" -> :rate_limit
      "transport_error" -> :transport_error
      "auth_error" -> :auth_error
      _ -> :unknown
    end
  end

  def normalize_kind(_kind), do: :unknown

  @spec truthy?(term()) :: boolean()
  def truthy?(value) when value in [true, "true", 1, "1", "yes", "on"], do: true
  def truthy?(_value), do: false

  @spec int_value(map(), [atom() | String.t()], non_neg_integer()) :: non_neg_integer()
  def int_value(raw, keys, default \\ 0) when is_map(raw) and is_list(keys) do
    case fetch_any(raw, keys) do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> trunc(value)
      value when is_binary(value) -> parse_int(value, default)
      _ -> default
    end
  end

  @spec float_value(map(), [atom() | String.t()], float()) :: float()
  def float_value(raw, keys, default \\ 0.0) when is_map(raw) and is_list(keys) do
    case fetch_any(raw, keys) do
      value when is_float(value) -> value
      value when is_integer(value) -> value * 1.0
      value when is_binary(value) -> parse_float(value, default)
      _ -> default
    end
  end

  @spec emit_single(Event.kind(), Event.payload(), term(), parser_state()) ::
          {[Event.t()], parser_state()}
  def emit_single(kind, payload, raw, state) do
    {event, state} = emit_event(kind, payload, raw, state)
    {[event], state}
  end

  @spec emit_event(Event.kind(), Event.payload(), term(), parser_state()) ::
          {Event.t(), parser_state()}
  def emit_event(kind, payload, raw, state) when is_map(state) do
    provider_session_id = state.provider_session_id
    next_state = bump_emitted(state)
    next_state = if kind == :result, do: mark_result_emitted(next_state), else: next_state

    event =
      Event.new(kind,
        provider: state.provider,
        payload: payload,
        raw: raw,
        provider_session_id: provider_session_id
      )

    {event, next_state}
  end

  @spec mark_result_emitted(parser_state()) :: parser_state()
  def mark_result_emitted(state) when is_map(state) do
    %{state | result_emitted?: true}
  end

  @spec extract_provider_session_id(map()) :: String.t() | nil
  def extract_provider_session_id(raw) when is_map(raw) do
    fetch_any(raw, [
      :provider_session_id,
      "provider_session_id",
      :session_id,
      "session_id",
      :sessionId,
      "sessionId",
      :conversation_id,
      "conversation_id",
      :thread_id,
      "thread_id",
      :run_id,
      "run_id"
    ])
    |> normalize_session_id()
  end

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env(_env), do: %{}

  defp maybe_put_provider_session_id(state, nil), do: state

  defp maybe_put_provider_session_id(state, provider_session_id) do
    %{state | provider_session_id: provider_session_id}
  end

  defp bump_emitted(state) do
    %{state | emitted: state.emitted + 1}
  end

  defp normalize_session_id(value) when is_binary(value) and value != "", do: value
  defp normalize_session_id(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_session_id(_value), do: nil

  defp parse_int(value, default) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp parse_float(value, default) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp normalize_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_code({:exit_status, code}) when is_integer(code), do: Integer.to_string(code)
  defp normalize_code(reason) when is_integer(reason), do: Integer.to_string(reason)
  defp normalize_code(_reason), do: "transport_exit"
end
