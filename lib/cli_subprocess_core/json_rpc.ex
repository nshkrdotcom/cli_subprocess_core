defmodule CliSubprocessCore.JSONRPC do
  @moduledoc """
  JSON-RPC helper on top of `CliSubprocessCore.ProtocolSession`.

  The helper owns generic JSON-RPC framing, request id allocation, response
  decoding, and peer-request reply encoding. Provider-specific methods, params,
  and schemas stay outside the core.
  """

  alias CliSubprocessCore.ProtocolSession

  defmodule Adapter do
    @moduledoc false

    @behaviour CliSubprocessCore.ProtocolAdapter

    defstruct next_id: 0,
              ready_matcher: nil

    @impl true
    def init(opts) when is_list(opts) do
      {:ok,
       %__MODULE__{
         next_id: Keyword.get(opts, :request_id_start, 0),
         ready_matcher: Keyword.get(opts, :ready_matcher)
       }, []}
    end

    @impl true
    def encode_request(request, %__MODULE__{} = state) do
      with {:ok, id, message} <- normalize_request(request, state.next_id) do
        next_id = if is_integer(id), do: max(state.next_id, id + 1), else: state.next_id
        frame = [Jason.encode_to_iodata!(message), "\n"] |> IO.iodata_to_binary()
        {:ok, id, frame, %{state | next_id: next_id}}
      end
    end

    @impl true
    def encode_notification(notification, %__MODULE__{} = state) do
      with {:ok, message} <- normalize_notification(notification) do
        frame = [Jason.encode_to_iodata!(message), "\n"] |> IO.iodata_to_binary()
        {:ok, frame, state}
      end
    end

    @impl true
    def handle_inbound(frame, %__MODULE__{} = state) when is_binary(frame) do
      case Jason.decode(frame) do
        {:ok, %{} = message} ->
          events =
            []
            |> maybe_add_ready_event(message, state.ready_matcher)
            |> Kernel.++([classify_message(message)])
            |> Enum.reject(&(&1 == :ignore))

          {:ok, events, state}

        {:ok, other} ->
          {:ok, [{:protocol_error, {:invalid_json_rpc_message, other}}], state}

        {:error, error} ->
          {:ok, [{:protocol_error, {:invalid_json, Exception.message(error)}}], state}
      end
    end

    @impl true
    def encode_peer_reply(correlation_key, {:ok, result}, %__MODULE__{} = state) do
      frame =
        %{"id" => correlation_key, "result" => result}
        |> Jason.encode_to_iodata!()
        |> then(&IO.iodata_to_binary([&1, "\n"]))

      {:ok, frame, state}
    end

    def encode_peer_reply(correlation_key, {:error, reason}, %__MODULE__{} = state) do
      frame =
        %{"id" => correlation_key, "error" => normalize_error(reason)}
        |> Jason.encode_to_iodata!()
        |> then(&IO.iodata_to_binary([&1, "\n"]))

      {:ok, frame, state}
    end

    defp normalize_request(%{} = request, next_id) do
      method = Map.get(request, :method) || Map.get(request, "method")
      params = Map.get(request, :params) || Map.get(request, "params")
      id = Map.get(request, :id) || Map.get(request, "id") || next_id

      if is_binary(method) do
        {:ok, id, put_optional(%{"id" => id, "method" => method}, "params", params)}
      else
        {:error, {:invalid_request, request}}
      end
    end

    defp normalize_request({method, params}, next_id) when is_binary(method) do
      {:ok, next_id, put_optional(%{"id" => next_id, "method" => method}, "params", params)}
    end

    defp normalize_request(method, next_id) when is_binary(method) do
      {:ok, next_id, %{"id" => next_id, "method" => method}}
    end

    defp normalize_request(other, _next_id), do: {:error, {:invalid_request, other}}

    defp normalize_notification(%{} = notification) do
      method = Map.get(notification, :method) || Map.get(notification, "method")
      params = Map.get(notification, :params) || Map.get(notification, "params")

      if is_binary(method) do
        {:ok, put_optional(%{"method" => method}, "params", params)}
      else
        {:error, {:invalid_notification, notification}}
      end
    end

    defp normalize_notification({method, params}) when is_binary(method) do
      {:ok, put_optional(%{"method" => method}, "params", params)}
    end

    defp normalize_notification(method) when is_binary(method) do
      {:ok, %{"method" => method}}
    end

    defp normalize_notification(other), do: {:error, {:invalid_notification, other}}

    defp classify_message(%{"id" => id, "method" => _method} = message),
      do: {:peer_request, id, message}

    defp classify_message(%{"id" => id, "result" => result}),
      do: {:response, id, {:ok, result}}

    defp classify_message(%{"id" => id, "error" => error}),
      do: {:response, id, {:error, error}}

    defp classify_message(%{"method" => _method} = message), do: {:notification, message}
    defp classify_message(_message), do: :ignore

    defp maybe_add_ready_event(events, _message, nil), do: events

    defp maybe_add_ready_event(events, message, ready_matcher)
         when is_function(ready_matcher, 1) do
      if ready_matcher.(message) do
        [{:ready, message} | events]
      else
        events
      end
    end

    defp normalize_error(%{"code" => code, "message" => message} = error)
         when is_integer(code) and is_binary(message),
         do: error

    defp normalize_error(%{code: code, message: message} = error)
         when is_integer(code) and is_binary(message) do
      error
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> put_optional("data", Map.get(error, :data))
    end

    defp normalize_error({code, message}) when is_integer(code) and is_binary(message) do
      %{"code" => code, "message" => message}
    end

    defp normalize_error({code, message, data}) when is_integer(code) and is_binary(message) do
      %{"code" => code, "message" => message, "data" => data}
    end

    defp normalize_error(:timeout) do
      %{"code" => -32_000, "message" => "peer request handler timed out"}
    end

    defp normalize_error({:handler_exit, reason}) do
      %{"code" => -32_000, "message" => "peer request handler exited", "data" => inspect(reason)}
    end

    defp normalize_error({:handler_start_failed, reason}) do
      %{
        "code" => -32_000,
        "message" => "peer request handler failed to start",
        "data" => inspect(reason)
      }
    end

    defp normalize_error(:unsupported_peer_request) do
      %{"code" => -32_601, "message" => "unsupported peer request"}
    end

    defp normalize_error(reason) when is_binary(reason) do
      %{"code" => -32_000, "message" => reason}
    end

    defp normalize_error(reason) when is_atom(reason) do
      %{"code" => -32_000, "message" => Atom.to_string(reason)}
    end

    defp normalize_error(reason) do
      %{"code" => -32_000, "message" => inspect(reason)}
    end

    defp put_optional(map, _key, nil), do: map
    defp put_optional(map, _key, []), do: map
    defp put_optional(map, key, value), do: Map.put(map, key, value)
  end

  @doc """
  Starts an unlinked JSON-RPC session.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) when is_list(opts) do
    ProtocolSession.start(protocol_session_opts(opts))
  end

  @doc """
  Starts a linked JSON-RPC session.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    ProtocolSession.start_link(protocol_session_opts(opts))
  end

  @doc """
  Waits for the JSON-RPC session to become ready.
  """
  @spec await_ready(pid(), pos_integer()) :: :ok | {:error, term()}
  def await_ready(session, timeout_ms), do: ProtocolSession.await_ready(session, timeout_ms)

  @doc """
  Sends a JSON-RPC request.
  """
  @spec request(pid(), String.t(), map() | list() | nil, keyword()) ::
          {:ok, term()} | {:error, term()}
  def request(session, method, params \\ nil, opts \\ [])
      when is_pid(session) and is_binary(method) and is_list(opts) do
    ProtocolSession.request(session, %{method: method, params: params}, opts)
  end

  @doc """
  Sends a JSON-RPC notification.
  """
  @spec notify(pid(), String.t(), map() | list() | nil) :: :ok | {:error, term()}
  def notify(session, method, params \\ nil) when is_pid(session) and is_binary(method) do
    ProtocolSession.notify(session, %{method: method, params: params})
  end

  @doc """
  Interrupts the underlying session.
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session), do: ProtocolSession.interrupt(session)

  @doc """
  Stops the JSON-RPC session.
  """
  @spec close(pid()) :: :ok
  def close(session), do: ProtocolSession.close(session)

  @doc """
  Returns JSON-RPC session information.
  """
  @spec info(pid()) :: map()
  def info(session), do: ProtocolSession.info(session)

  defp protocol_session_opts(opts) do
    {adapter_opts, protocol_opts} =
      Keyword.split(opts, [:ready_matcher, :request_id_start])

    protocol_opts
    |> Keyword.put(:adapter, Adapter)
    |> Keyword.put(:adapter_options, adapter_opts)
  end
end
