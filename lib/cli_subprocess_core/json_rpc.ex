defmodule CliSubprocessCore.JSONRPC do
  @moduledoc """
  JSON-RPC helper on top of `CliSubprocessCore.ProtocolSession`.

  The helper owns generic JSON-RPC framing, request id allocation, response
  decoding, and peer-request reply encoding. Provider-specific methods, params,
  and schemas stay outside the core.
  """

  alias CliSubprocessCore.ProtocolSession

  @type t :: ProtocolSession.t()
  @type info_t :: ProtocolSession.info_t()

  defmodule Adapter do
    @moduledoc false
    defdelegate init(opts), to: ExecutionPlane.Protocols.JsonRpc.Adapter
    defdelegate encode_request(request, state), to: ExecutionPlane.Protocols.JsonRpc.Adapter

    defdelegate encode_notification(notification, state),
      to: ExecutionPlane.Protocols.JsonRpc.Adapter

    defdelegate handle_inbound(frame, state), to: ExecutionPlane.Protocols.JsonRpc.Adapter

    defdelegate encode_peer_reply(correlation_key, result, state),
      to: ExecutionPlane.Protocols.JsonRpc.Adapter
  end

  @doc """
  Starts an unlinked JSON-RPC session.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
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
  @spec await_ready(t(), pos_integer()) :: :ok | {:error, term()}
  def await_ready(session, timeout_ms), do: ProtocolSession.await_ready(session, timeout_ms)

  @doc """
  Sends a JSON-RPC request.
  """
  @spec request(t(), String.t(), map() | list() | nil, keyword()) ::
          {:ok, term()} | {:error, term()}
  def request(session, method, params \\ nil, opts \\ [])
      when is_pid(session) and is_binary(method) and is_list(opts) do
    ProtocolSession.request(session, %{method: method, params: params}, opts)
  end

  @doc """
  Sends a JSON-RPC notification.
  """
  @spec notify(t(), String.t(), map() | list() | nil) :: :ok | {:error, term()}
  def notify(session, method, params \\ nil) when is_pid(session) and is_binary(method) do
    ProtocolSession.notify(session, %{method: method, params: params})
  end

  @doc """
  Interrupts the underlying session.
  """
  @spec interrupt(t()) :: :ok | {:error, term()}
  def interrupt(session), do: ProtocolSession.interrupt(session)

  @doc """
  Stops the JSON-RPC session.
  """
  @spec close(t()) :: :ok
  def close(session), do: ProtocolSession.close(session)

  @doc """
  Returns JSON-RPC session information.
  """
  @spec info(t()) :: info_t()
  def info(session), do: ProtocolSession.info(session)

  defp protocol_session_opts(opts) do
    {adapter_opts, protocol_opts} =
      Keyword.split(opts, [:ready_matcher, :request_id_start])

    protocol_opts
    |> Keyword.put(:adapter, Adapter)
    |> Keyword.put(:adapter_options, adapter_opts)
  end
end
