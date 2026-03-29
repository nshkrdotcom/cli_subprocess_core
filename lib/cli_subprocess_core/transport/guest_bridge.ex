# credo:disable-for-this-file Credo.Check.Warning.StructFieldAmount

defmodule CliSubprocessCore.Transport.GuestBridge do
  @moduledoc false

  use GenServer

  import Kernel, except: [send: 2]

  alias CliSubprocessCore.{
    Command,
    ExecutionSurface.Adapter,
    ExecutionSurface.Capabilities,
    LineFraming,
    ProcessExit,
    Transport,
    Transport.Error,
    Transport.Info,
    Transport.Options,
    Transport.RunResult
  }

  alias CliSubprocessCore.Transport.GuestBridge.Protocol

  @behaviour Adapter
  @behaviour Transport

  @surface_kind :guest_bridge
  @default_bridge_profile "core_cli_transport"
  @default_protocol_versions [1]
  @default_request_timeout_ms 5_000
  @default_connect_timeout_ms 5_000

  defstruct socket: nil,
            buffer: "",
            invocation: nil,
            surface_kind: @surface_kind,
            transport_options: [],
            target_id: nil,
            lease_ref: nil,
            surface_ref: nil,
            boundary_class: nil,
            observability: %{},
            adapter_capabilities: nil,
            effective_capabilities: nil,
            bridge_profile: nil,
            protocol_version: nil,
            extensions: %{},
            adapter_metadata: %{},
            status: :disconnected,
            stdout_mode: :line,
            stdin_mode: :line,
            pty?: false,
            interrupt_mode: :signal,
            stderr_buffer: "",
            stdout_framer: %LineFraming{},
            subscribers: %{},
            event_tag: :cli_subprocess_core,
            replay_stderr_on_subscribe?: false,
            buffer_events_until_subscribe?: false,
            buffered_events: :queue.new(),
            buffered_event_count: 0,
            max_buffered_events: 128,
            pending_requests: %{},
            request_seq: 0

  @type subscriber_info :: %{
          monitor_ref: reference(),
          tag: Transport.subscription_tag()
        }

  @type endpoint ::
          %{kind: :unix_socket, path: String.t()}
          | %{kind: :tcp, host: String.t(), port: pos_integer()}

  @impl Adapter
  def surface_kind, do: @surface_kind

  @impl Adapter
  def capabilities do
    Capabilities.new!(
      remote?: true,
      startup_kind: :bridge,
      path_semantics: :guest,
      supports_run?: true,
      supports_streaming_stdio?: true,
      supports_pty?: true,
      supports_user?: true,
      supports_env?: true,
      supports_cwd?: true,
      interrupt_kind: :rpc
    )
  end

  @impl Adapter
  def normalize_transport_options(options) do
    with {:ok, keyword_options} <- normalize_transport_options_shape(options),
         :ok <- reject_unknown_transport_option_keys(keyword_options),
         {:ok, endpoint} <- normalize_endpoint(Keyword.get(keyword_options, :endpoint)),
         {:ok, bridge_ref} <-
           normalize_required_binary(Keyword.get(keyword_options, :bridge_ref), :bridge_ref),
         {:ok, attach_token} <-
           normalize_optional_binary(Keyword.get(keyword_options, :attach_token), :attach_token),
         {:ok, bridge_profile} <-
           normalize_required_binary(
             Keyword.get(keyword_options, :bridge_profile),
             :bridge_profile
           ),
         {:ok, supported_protocol_versions} <-
           normalize_supported_protocol_versions(
             Keyword.get(keyword_options, :supported_protocol_versions)
           ),
         {:ok, extensions} <-
           normalize_extensions(Keyword.get(keyword_options, :extensions, %{})),
         {:ok, connect_timeout_ms} <-
           normalize_optional_timeout(
             Keyword.get(keyword_options, :connect_timeout_ms),
             :connect_timeout_ms
           ),
         {:ok, request_timeout_ms} <-
           normalize_optional_timeout(
             Keyword.get(keyword_options, :request_timeout_ms),
             :request_timeout_ms
           ) do
      {:ok,
       [
         endpoint: endpoint,
         bridge_ref: bridge_ref,
         attach_token: attach_token,
         bridge_profile: bridge_profile,
         supported_protocol_versions: supported_protocol_versions,
         extensions: extensions,
         connect_timeout_ms: connect_timeout_ms,
         request_timeout_ms: request_timeout_ms
       ]}
    end
  end

  @impl Transport
  def start(opts) when is_list(opts) do
    case Options.new(opts) do
      {:ok, options} ->
        case GenServer.start(__MODULE__, options) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:transport, %Error{} = error}} -> transport_error(error)
          {:error, reason} -> transport_error(reason)
        end

      {:error, {:invalid_transport_options, reason}} ->
        transport_error(Error.invalid_options(reason))
    end
  catch
    :exit, reason ->
      transport_error(reason)
  end

  @impl Transport
  def start_link(opts) when is_list(opts) do
    case Options.new(opts) do
      {:ok, options} ->
        case GenServer.start_link(__MODULE__, options) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:transport, %Error{} = error}} -> transport_error(error)
          {:error, reason} -> transport_error(reason)
        end

      {:error, {:invalid_transport_options, reason}} ->
        transport_error(Error.invalid_options(reason))
    end
  catch
    :exit, reason ->
      transport_error(reason)
  end

  @impl Transport
  def run(%Command{} = command, opts) when is_list(opts) do
    adapter_capabilities = Keyword.get(opts, :adapter_capabilities) || capabilities()

    {:ok, transport_options} = fetch_transport_options(opts)

    case connect_endpoint(transport_options) do
      {:ok, socket} ->
        try do
          with {:ok, attach_result} <-
                 perform_attach(
                   socket,
                   transport_options,
                   opts,
                   required_capabilities_for_command(command, :run),
                   adapter_capabilities
                 ),
               {:ok, effective_capabilities} <-
                 validate_attach_result(
                   attach_result,
                   transport_options,
                   adapter_capabilities
                 ),
               :ok <- validate_effective_capabilities(command, effective_capabilities, :run),
               {:ok, payload} <-
                 run_request(socket, command, effective_capabilities, transport_options),
               {:ok, result} <- run_result_from_payload(payload, command) do
            {:ok, result}
          else
            {:error, %Error{} = error} ->
              transport_error(error)

            {:error, reason} ->
              transport_error(reason)
          end
        after
          close_socket(socket)
        end

      {:error, %Error{} = error} ->
        transport_error(error)
    end
  end

  @impl Transport
  def send(transport, message) do
    GenServer.call(transport, {:send, message})
  catch
    :exit, reason -> transport_error(reason)
  end

  @impl Transport
  def subscribe(transport, pid) do
    subscribe(transport, pid, :legacy)
  end

  @impl Transport
  def subscribe(transport, pid, tag)
      when is_pid(transport) and is_pid(pid) and (tag == :legacy or is_reference(tag)) do
    GenServer.call(transport, {:subscribe, pid, tag})
  catch
    :exit, reason -> transport_error(reason)
  end

  @impl Transport
  def unsubscribe(transport, pid) when is_pid(transport) and is_pid(pid) do
    GenServer.call(transport, {:unsubscribe, pid})
  catch
    :exit, _reason -> :ok
  end

  @impl Transport
  def close(transport) when is_pid(transport) do
    GenServer.stop(transport, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl Transport
  def force_close(transport) when is_pid(transport) do
    GenServer.stop(transport, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl Transport
  def interrupt(transport) when is_pid(transport) do
    GenServer.call(transport, :interrupt)
  catch
    :exit, reason -> transport_error(reason)
  end

  @impl Transport
  def status(transport) when is_pid(transport) do
    GenServer.call(transport, :status)
  catch
    :exit, _reason -> :disconnected
  end

  @impl Transport
  def end_input(transport) when is_pid(transport) do
    GenServer.call(transport, :end_input)
  catch
    :exit, reason -> transport_error(reason)
  end

  @impl Transport
  def stderr(transport) when is_pid(transport) do
    GenServer.call(transport, :stderr)
  catch
    :exit, _reason -> ""
  end

  @impl Transport
  def info(transport) when is_pid(transport) do
    GenServer.call(transport, :info)
  catch
    :exit, _reason -> Info.disconnected()
  end

  @impl GenServer
  def init(%Options{} = options) do
    Process.flag(:trap_exit, true)

    adapter_capabilities = options.adapter_capabilities || capabilities()
    state = build_state(options, adapter_capabilities)

    with {:ok, transport_options} <- fetch_transport_options(options),
         {:ok, socket} <- connect_endpoint(transport_options),
         {:ok, attach_result} <-
           perform_attach(
             socket,
             transport_options,
             options,
             required_capabilities_for_options(options, :start_session),
             adapter_capabilities
           ),
         {:ok, effective_capabilities} <-
           validate_attach_result(attach_result, transport_options, adapter_capabilities),
         :ok <- validate_effective_capabilities(options, effective_capabilities, :start_session),
         {:ok, start_payload} <-
           start_session_request(socket, options, effective_capabilities, transport_options),
         {:ok, _response_payload} <- expect_ok_payload(start_payload),
         :ok <- set_active_once(socket) do
      {:ok,
       %{
         state
         | socket: socket,
           status: :connected,
           effective_capabilities: effective_capabilities,
           bridge_profile: attach_result.bridge_profile,
           protocol_version: attach_result.protocol_version,
           extensions: attach_result.extensions,
           adapter_metadata:
             Map.merge(state.adapter_metadata, %{
               bridge_session_ref: attach_result.bridge_session_ref
             })
       }}
    else
      {:error, %Error{} = error} ->
        {:stop, {:transport, error}}

      {:error, reason} ->
        {:stop, {:transport, normalize_transport_error(reason)}}
    end
  end

  @impl GenServer
  def handle_call({:send, message}, from, %{status: :connected} = state) do
    case validate_runtime_capability(
           state.effective_capabilities,
           :streaming_stdio,
           state.surface_kind
         ) do
      :ok ->
        payload =
          message
          |> normalize_payload()
          |> maybe_ensure_newline(state.stdin_mode)

        queue_request(state, from, "stdin", %{"data" => Protocol.encode_bytes(payload)})

      {:error, %Error{} = error} ->
        {:reply, transport_error(error), state}
    end
  end

  def handle_call({:send, _message}, _from, state),
    do: {:reply, transport_error(Error.not_connected()), state}

  def handle_call({:subscribe, pid, tag}, _from, state) do
    {:reply, :ok,
     state
     |> put_subscriber(pid, tag)
     |> maybe_replay_stderr(pid)
     |> maybe_replay_buffered_events(pid, tag)}
  end

  def handle_call({:unsubscribe, pid}, _from, state),
    do: {:reply, :ok, drop_subscriber(state, pid)}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  def handle_call(:stderr, _from, state), do: {:reply, state.stderr_buffer, state}
  def handle_call(:info, _from, state), do: {:reply, transport_info(state), state}

  def handle_call(:end_input, from, %{status: :connected} = state) do
    queue_request(state, from, "stdin_eof", %{})
  end

  def handle_call(:end_input, _from, state),
    do: {:reply, transport_error(Error.not_connected()), state}

  def handle_call(
        :interrupt,
        from,
        %{status: :connected, effective_capabilities: capabilities} = state
      ) do
    if capabilities && capabilities.interrupt_kind == :rpc do
      queue_request(state, from, "interrupt", %{})
    else
      {:reply, transport_error(Error.unsupported_capability(:interrupt, @surface_kind)), state}
    end
  end

  def handle_call(:interrupt, _from, state),
    do: {:reply, transport_error(Error.not_connected()), state}

  @impl GenServer
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    state =
      state
      |> append_buffer(IO.iodata_to_binary(data))
      |> consume_frames()

    _ = set_active_once(socket)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    {:noreply, disconnect(state, :disconnected)}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    error = Error.bridge_protocol_error({:socket_error, reason})
    state = state |> emit_event({:error, error}) |> disconnect(:error)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      Enum.reject(state.subscribers, fn {subscriber_pid, info} ->
        info.monitor_ref == ref or pid == subscriber_pid
      end)
      |> Map.new()

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    maybe_send_close_frame(state)
    close_socket(state.socket)
    demonitor_subscribers(state.subscribers)
    cleanup_pending_requests(state.pending_requests)
    :ok
  end

  defp build_state(%Options{} = options, %Capabilities{} = adapter_capabilities) do
    %__MODULE__{
      invocation: options.invocation_override || build_invocation(options),
      transport_options: options.transport_options,
      target_id: options.target_id,
      lease_ref: options.lease_ref,
      surface_ref: options.surface_ref,
      boundary_class: options.boundary_class,
      observability: options.observability,
      adapter_capabilities: adapter_capabilities,
      status: :disconnected,
      stdout_mode: options.stdout_mode,
      stdin_mode: options.stdin_mode,
      pty?: options.pty?,
      interrupt_mode: options.interrupt_mode,
      event_tag: options.event_tag,
      replay_stderr_on_subscribe?: options.replay_stderr_on_subscribe?,
      buffer_events_until_subscribe?: options.buffer_events_until_subscribe?,
      max_buffered_events: options.max_buffered_events,
      adapter_metadata: %{
        endpoint: Keyword.get(options.transport_options, :endpoint),
        bridge_ref: Keyword.get(options.transport_options, :bridge_ref)
      }
    }
  end

  defp fetch_transport_options(%Options{transport_options: transport_options}),
    do: {:ok, transport_options}

  defp fetch_transport_options(opts) when is_list(opts),
    do: {:ok, Keyword.get(opts, :transport_options, [])}

  defp normalize_transport_options_shape(nil), do: {:error, {:invalid_transport_options, nil}}

  defp normalize_transport_options_shape(options) when is_list(options) do
    if Keyword.keyword?(options) do
      {:ok, options}
    else
      {:error, {:invalid_transport_options, options}}
    end
  end

  defp normalize_transport_options_shape(options) when is_map(options) do
    if Enum.all?(Map.keys(options), &(is_atom(&1) or is_binary(&1))) do
      {:ok, Enum.map(options, fn {key, value} -> {normalize_option_key(key), value} end)}
    else
      {:error, {:invalid_transport_options, options}}
    end
  end

  defp normalize_transport_options_shape(options),
    do: {:error, {:invalid_transport_options, options}}

  defp reject_unknown_transport_option_keys(options) when is_list(options) do
    allowed =
      ~w(endpoint bridge_ref attach_token bridge_profile supported_protocol_versions extensions connect_timeout_ms request_timeout_ms)a

    unknown =
      options
      |> Keyword.keys()
      |> Enum.reject(&(&1 in allowed))

    if unknown == [] do
      :ok
    else
      {:error, {:invalid_transport_options, {:unknown_transport_option_keys, unknown}}}
    end
  end

  defp normalize_option_key(key) when is_atom(key), do: key

  defp normalize_option_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize_required_binary(value, _field) when is_binary(value) and value != "",
    do: {:ok, value}

  defp normalize_required_binary(value, field),
    do: {:error, {:invalid_transport_options, {field, value}}}

  defp normalize_optional_binary(nil, _field), do: {:ok, nil}

  defp normalize_optional_binary(value, _field) when is_binary(value) and value != "",
    do: {:ok, value}

  defp normalize_optional_binary(value, field),
    do: {:error, {:invalid_transport_options, {field, value}}}

  defp normalize_supported_protocol_versions(versions)
       when is_list(versions) and versions != [] do
    if Enum.all?(versions, &(is_integer(&1) and &1 > 0)) do
      {:ok, versions}
    else
      {:error, {:invalid_transport_options, {:supported_protocol_versions, versions}}}
    end
  end

  defp normalize_supported_protocol_versions(other),
    do: {:error, {:invalid_transport_options, {:supported_protocol_versions, other}}}

  defp normalize_optional_timeout(nil, _field), do: {:ok, nil}

  defp normalize_optional_timeout(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_optional_timeout(value, field),
    do: {:error, {:invalid_transport_options, {field, value}}}

  defp normalize_extensions(extensions) when is_map(extensions), do: {:ok, extensions}

  defp normalize_extensions(other),
    do: {:error, {:invalid_transport_options, {:extensions, other}}}

  defp normalize_endpoint(%{"kind" => kind} = endpoint) do
    normalize_endpoint(%{
      kind: normalize_endpoint_kind(kind),
      path: Map.get(endpoint, "path"),
      host: Map.get(endpoint, "host"),
      port: Map.get(endpoint, "port")
    })
  end

  defp normalize_endpoint(%{kind: :unix_socket, path: path})
       when is_binary(path) and path != "" do
    {:ok, %{kind: :unix_socket, path: path}}
  end

  defp normalize_endpoint(%{kind: :tcp, host: host, port: port})
       when is_binary(host) and host != "" and is_integer(port) and port > 0 do
    {:ok, %{kind: :tcp, host: host, port: port}}
  end

  defp normalize_endpoint(other), do: {:error, {:invalid_transport_options, {:endpoint, other}}}

  defp normalize_endpoint_kind(kind) when is_atom(kind), do: kind
  defp normalize_endpoint_kind("unix_socket"), do: :unix_socket
  defp normalize_endpoint_kind("tcp"), do: :tcp
  defp normalize_endpoint_kind(other), do: other

  defp connect_endpoint(transport_options) when is_list(transport_options) do
    timeout = Keyword.get(transport_options, :connect_timeout_ms) || @default_connect_timeout_ms

    case Keyword.fetch!(transport_options, :endpoint) do
      %{kind: :tcp, host: host, port: port} ->
        case :gen_tcp.connect(
               String.to_charlist(host),
               port,
               [:binary, active: false, packet: 0],
               timeout
             ) do
          {:ok, socket} -> {:ok, socket}
          {:error, reason} -> {:error, Error.startup_failed({:bridge_connect_failed, reason})}
        end

      %{kind: :unix_socket, path: path} ->
        case :gen_tcp.connect(
               {:local, String.to_charlist(path)},
               0,
               [:binary, active: false, packet: 0],
               timeout
             ) do
          {:ok, socket} -> {:ok, socket}
          {:error, reason} -> {:error, Error.startup_failed({:bridge_connect_failed, reason})}
        end
    end
  end

  defp perform_attach(
         socket,
         transport_options,
         options_or_opts,
         required_capabilities,
         adapter_capabilities
       ) do
    request_timeout_ms =
      Keyword.get(transport_options, :request_timeout_ms) || @default_request_timeout_ms

    request_id = "attach-1"

    payload = %{
      "bridge_profile" =>
        Keyword.get(transport_options, :bridge_profile, @default_bridge_profile),
      "supported_protocol_versions" =>
        Keyword.get(transport_options, :supported_protocol_versions, @default_protocol_versions),
      "required_capabilities" => Protocol.capabilities_to_external(required_capabilities),
      "optional_capabilities" => Protocol.capabilities_to_external(adapter_capabilities),
      "bridge_ref" => Keyword.fetch!(transport_options, :bridge_ref),
      "attach_token" => Keyword.get(transport_options, :attach_token),
      "target_id" => fetch_option(options_or_opts, :target_id),
      "lease_ref" => fetch_option(options_or_opts, :lease_ref),
      "surface_ref" => fetch_option(options_or_opts, :surface_ref),
      "boundary_class" => encode_atomish(fetch_option(options_or_opts, :boundary_class)),
      "extensions" => Keyword.get(transport_options, :extensions, %{})
    }

    with :ok <- send_frame(socket, Protocol.request(request_id, "attach", payload)),
         {:ok, %{} = response_payload} <- recv_ok_payload(socket, request_id, request_timeout_ms) do
      {:ok,
       %{
         bridge_session_ref: Map.get(response_payload, "bridge_session_ref"),
         bridge_profile: Map.get(response_payload, "bridge_profile"),
         protocol_version: Map.get(response_payload, "protocol_version"),
         effective_capabilities: Map.get(response_payload, "effective_capabilities", %{}),
         extensions: Map.get(response_payload, "extensions", %{})
       }}
    end
  end

  defp validate_attach_result(attach_result, transport_options, adapter_capabilities) do
    with true <-
           attach_result.bridge_profile ==
             Keyword.get(transport_options, :bridge_profile, @default_bridge_profile) or
             {:error,
              Error.bridge_protocol_error(
                {:bridge_profile_mismatch, attach_result.bridge_profile}
              )},
         true <-
           attach_result.protocol_version in Keyword.get(
             transport_options,
             :supported_protocol_versions,
             @default_protocol_versions
           ) or
             {:error,
              Error.bridge_protocol_error(
                {:unsupported_protocol_version, attach_result.protocol_version}
              )},
         {:ok, effective_capabilities} <-
           Protocol.capabilities_from_external(attach_result.effective_capabilities),
         true <-
           Capabilities.subset?(effective_capabilities, adapter_capabilities) or
             {:error,
              Error.bridge_protocol_error(
                {:capability_superset, attach_result.effective_capabilities}
              )} do
      {:ok, effective_capabilities}
    else
      {:error, _reason} = error -> error
    end
  end

  defp start_session_request(
         socket,
         %Options{} = options,
         effective_capabilities,
         transport_options
       ) do
    request_timeout_ms =
      Keyword.get(transport_options, :request_timeout_ms) || @default_request_timeout_ms

    payload = launch_payload(build_invocation(options), effective_capabilities)
    request_id = "start-session-1"

    case send_frame(socket, Protocol.request(request_id, "start_session", payload)) do
      :ok -> recv_ok_payload(socket, request_id, request_timeout_ms)
      error -> error
    end
  end

  defp run_request(socket, %Command{} = command, effective_capabilities, transport_options) do
    request_timeout_ms =
      Keyword.get(transport_options, :request_timeout_ms) || @default_request_timeout_ms

    payload = launch_payload(command, effective_capabilities)
    request_id = "run-1"

    case send_frame(socket, Protocol.request(request_id, "run", payload)) do
      :ok -> recv_ok_payload(socket, request_id, request_timeout_ms)
      error -> error
    end
  end

  defp recv_ok_payload(socket, request_id, timeout_ms) do
    case recv_response(socket, request_id, timeout_ms, <<>>) do
      {:ok, %{} = response} -> expect_ok_payload(response)
      error -> error
    end
  end

  defp recv_response(socket, request_id, timeout_ms, buffer) do
    case Protocol.decode_frames(buffer) do
      {:ok, frames, rest} ->
        case find_matching_response(frames, request_id) do
          {:ok, frame} ->
            {:ok, frame}

          :not_found ->
            recv_next_response(socket, request_id, timeout_ms, rest)
        end

      {:error, reason} ->
        {:error, Error.bridge_protocol_error(reason)}
    end
  end

  defp find_matching_response(frames, request_id) when is_list(frames) do
    case Enum.find(frames, &matching_response?(&1, request_id)) do
      nil -> :not_found
      frame -> {:ok, frame}
    end
  end

  defp recv_next_response(socket, request_id, timeout_ms, buffer) do
    case :gen_tcp.recv(socket, 0, timeout_ms) do
      {:ok, data} -> recv_response(socket, request_id, timeout_ms, buffer <> data)
      {:error, reason} -> {:error, Error.bridge_protocol_error({:recv_failed, reason})}
    end
  end

  defp matching_response?(%{"kind" => "response", "id" => id}, request_id), do: id == request_id
  defp matching_response?(_, _request_id), do: false

  defp expect_ok_payload(%{"ok" => true, "payload" => payload}) when is_map(payload),
    do: {:ok, payload}

  defp expect_ok_payload(%{"ok" => false, "error" => %{} = error_payload}) do
    code = Map.get(error_payload, "code")
    details = Map.get(error_payload, "details", error_payload)

    case code do
      "unsupported_capability" ->
        capability =
          error_payload
          |> Map.get("capability")
          |> decode_atomish()

        {:error, Error.unsupported_capability(capability || :unknown, @surface_kind)}

      other ->
        {:error, Error.bridge_remote_error(other, details)}
    end
  end

  defp expect_ok_payload(other),
    do: {:error, Error.bridge_protocol_error({:invalid_response, other})}

  defp validate_effective_capabilities(options_or_command, capabilities, operation) do
    required =
      case operation do
        :run -> required_capabilities_for_command(options_or_command, :run)
        :start_session -> required_capabilities_for_options(options_or_command, :start_session)
      end

    if Capabilities.satisfies_requirements?(capabilities, required) do
      :ok
    else
      capability =
        required
        |> Map.keys()
        |> List.first()
        |> capability_key_to_name()

      {:error, Error.unsupported_capability(capability, @surface_kind)}
    end
  end

  defp required_capabilities_for_options(%Options{} = options, :start_session) do
    %{}
    |> maybe_require(:supports_streaming_stdio?, true)
    |> maybe_require(:supports_cwd?, is_binary(options.cwd) and options.cwd != "")
    |> maybe_require(:supports_env?, map_size(options.env) > 0 or options.clear_env?)
    |> maybe_require(:supports_user?, is_binary(options.user) and options.user != "")
    |> maybe_require(:supports_pty?, options.pty?)
  end

  defp required_capabilities_for_command(%Command{} = command, :run) do
    %{}
    |> maybe_require(:supports_run?, true)
    |> maybe_require(:supports_cwd?, is_binary(command.cwd) and command.cwd != "")
    |> maybe_require(:supports_env?, map_size(command.env) > 0 or command.clear_env?)
    |> maybe_require(:supports_user?, is_binary(command.user) and command.user != "")
  end

  defp maybe_require(acc, _key, false), do: acc
  defp maybe_require(acc, key, true), do: Map.put(acc, key, true)

  defp capability_key_to_name(:supports_streaming_stdio?), do: :streaming_stdio
  defp capability_key_to_name(:supports_run?), do: :run
  defp capability_key_to_name(:supports_cwd?), do: :cwd
  defp capability_key_to_name(:supports_env?), do: :env
  defp capability_key_to_name(:supports_user?), do: :user
  defp capability_key_to_name(:supports_pty?), do: :pty
  defp capability_key_to_name(_other), do: :unknown

  defp queue_request(state, from, op, payload) do
    request_id = Integer.to_string(state.request_seq + 1)

    case send_frame(state.socket, Protocol.request(request_id, op, payload)) do
      :ok ->
        {:noreply,
         %{
           state
           | request_seq: state.request_seq + 1,
             pending_requests: Map.put(state.pending_requests, request_id, from)
         }}

      {:error, %Error{} = error} ->
        {:reply, transport_error(error), state}
    end
  end

  defp send_frame(socket, frame) when is_port(socket) or is_tuple(socket) do
    case :gen_tcp.send(socket, Protocol.encode_frame(frame)) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.send_failed({:bridge_send_failed, reason})}
    end
  end

  defp set_active_once(socket) when is_port(socket) or is_tuple(socket) do
    :inet.setopts(socket, active: :once)
  end

  defp close_socket(nil), do: :ok
  defp close_socket(socket), do: :gen_tcp.close(socket)

  defp append_buffer(state, chunk), do: %{state | buffer: state.buffer <> chunk}

  defp consume_frames(state) do
    case Protocol.decode_frames(state.buffer) do
      {:ok, frames, rest} ->
        Enum.reduce(frames, %{state | buffer: rest}, &handle_frame/2)

      {:error, reason} ->
        error = Error.bridge_protocol_error(reason)
        state |> emit_event({:error, error}) |> disconnect(:error)
    end
  end

  defp handle_frame(%{"kind" => "response", "id" => id} = frame, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, pending_requests} ->
        %{state | pending_requests: pending_requests}

      {from, pending_requests} ->
        reply =
          case expect_ok_payload(frame) do
            {:ok, _payload} -> :ok
            {:error, %Error{} = error} -> transport_error(error)
          end

        GenServer.reply(from, reply)
        %{state | pending_requests: pending_requests}
    end
  end

  defp handle_frame(%{"kind" => "event", "event" => "stdout", "payload" => payload}, state) do
    with {:ok, encoded} <- fetch_binary(payload, "data"),
         {:ok, chunk} <- Protocol.decode_bytes(encoded) do
      append_stdout_chunk(state, chunk || "")
    else
      _other ->
        state
        |> emit_event({:error, Error.bridge_protocol_error({:invalid_stdout_event, payload})})
    end
  end

  defp handle_frame(%{"kind" => "event", "event" => "stderr", "payload" => payload}, state) do
    with {:ok, encoded} <- fetch_binary(payload, "data"),
         {:ok, chunk} <- Protocol.decode_bytes(encoded) do
      append_stderr_chunk(state, chunk || "")
    else
      _other ->
        state
        |> emit_event({:error, Error.bridge_protocol_error({:invalid_stderr_event, payload})})
    end
  end

  defp handle_frame(%{"kind" => "event", "event" => "exit", "payload" => payload}, state) do
    case exit_from_payload(payload, state.stderr_buffer) do
      {:ok, exit} ->
        state
        |> flush_stdout_fragment()
        |> emit_event({:exit, exit})
        |> Map.put(:status, :disconnected)

      {:error, %Error{} = error} ->
        state |> emit_event({:error, error}) |> Map.put(:status, :error)
    end
  end

  defp handle_frame(%{"kind" => "event", "event" => "error", "payload" => payload}, state) do
    error =
      case Map.get(payload, "code") do
        "unsupported_capability" ->
          capability =
            payload
            |> Map.get("capability")
            |> decode_atomish()

          Error.unsupported_capability(capability || :unknown, @surface_kind)

        code ->
          Error.bridge_remote_error(code, Map.get(payload, "details", payload))
      end

    emit_event(state, {:error, error})
  end

  defp handle_frame(_frame, state), do: state

  defp append_stdout_chunk(state, chunk) when state.stdout_mode == :raw do
    emit_event(state, {:data, chunk})
  end

  defp append_stdout_chunk(state, chunk) when is_binary(chunk) do
    {lines, stdout_framer} = LineFraming.push(state.stdout_framer, chunk)

    state =
      Enum.reduce(lines, %{state | stdout_framer: stdout_framer}, fn line, acc ->
        emit_event(acc, {:message, line})
      end)

    %{state | stdout_framer: stdout_framer}
  end

  defp flush_stdout_fragment(%{stdout_mode: :raw} = state), do: state

  defp flush_stdout_fragment(%{stdout_framer: %LineFraming{buffer: ""}} = state), do: state

  defp flush_stdout_fragment(state) do
    {lines, stdout_framer} = LineFraming.flush(state.stdout_framer)

    Enum.reduce(lines, %{state | stdout_framer: stdout_framer}, fn line, acc ->
      emit_event(acc, {:message, line})
    end)
  end

  defp append_stderr_chunk(state, chunk) when is_binary(chunk) do
    stderr_buffer = trim_stderr_buffer(state.stderr_buffer <> chunk)
    state = %{state | stderr_buffer: stderr_buffer}
    emit_event(state, {:stderr, chunk})
  end

  defp trim_stderr_buffer(buffer) when byte_size(buffer) <= 262_144, do: buffer

  defp trim_stderr_buffer(buffer) do
    size = byte_size(buffer)
    :binary.part(buffer, size - 262_144, 262_144)
  end

  defp emit_event(%{subscribers: subscribers} = state, event) when map_size(subscribers) > 0 do
    Enum.each(subscribers, fn {pid, info} -> dispatch_event(pid, info, event, state.event_tag) end)

    state
  end

  defp emit_event(%{buffer_events_until_subscribe?: true} = state, event) do
    buffer_event(state, event)
  end

  defp emit_event(state, _event), do: state

  defp dispatch_event(pid, %{tag: :legacy}, {:message, line}, _event_tag),
    do: Kernel.send(pid, {:transport_message, line})

  defp dispatch_event(pid, %{tag: :legacy}, {:data, chunk}, _event_tag),
    do: Kernel.send(pid, {:transport_data, chunk})

  defp dispatch_event(pid, %{tag: :legacy}, {:error, reason}, _event_tag),
    do: Kernel.send(pid, {:transport_error, reason})

  defp dispatch_event(pid, %{tag: :legacy}, {:stderr, data}, _event_tag),
    do: Kernel.send(pid, {:transport_stderr, data})

  defp dispatch_event(pid, %{tag: :legacy}, {:exit, reason}, _event_tag),
    do: Kernel.send(pid, {:transport_exit, reason})

  defp dispatch_event(pid, %{tag: ref}, event, event_tag) when is_reference(ref),
    do: Kernel.send(pid, {event_tag, ref, event})

  defp buffer_event(state, event) do
    buffered_events =
      if state.buffered_event_count >= state.max_buffered_events do
        {_dropped, queue} = :queue.out(state.buffered_events)
        :queue.in(event, queue)
      else
        :queue.in(event, state.buffered_events)
      end

    buffered_event_count = min(state.buffered_event_count + 1, state.max_buffered_events)
    %{state | buffered_events: buffered_events, buffered_event_count: buffered_event_count}
  end

  defp put_subscriber(state, pid, tag) do
    subscriber_info = %{monitor_ref: Process.monitor(pid), tag: tag}
    %{state | subscribers: Map.put(state.subscribers, pid, subscriber_info)}
  end

  defp maybe_replay_stderr(%{replay_stderr_on_subscribe?: true, stderr_buffer: data} = state, pid)
       when is_binary(data) and data != "" do
    dispatch_event(pid, %{tag: :legacy}, {:stderr, data}, state.event_tag)
    state
  end

  defp maybe_replay_stderr(state, _pid), do: state

  defp maybe_replay_buffered_events(%{buffered_event_count: 0} = state, _pid, _tag), do: state

  defp maybe_replay_buffered_events(state, pid, tag) do
    info = %{tag: tag}

    state.buffered_events
    |> :queue.to_list()
    |> Enum.each(fn event -> dispatch_event(pid, info, event, state.event_tag) end)

    %{state | buffered_events: :queue.new(), buffered_event_count: 0}
  end

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, subscribers} ->
        %{state | subscribers: subscribers}

      {%{monitor_ref: ref}, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  defp maybe_send_close_frame(%{status: :connected, socket: socket} = state)
       when not is_nil(socket) do
    _ = send_frame(socket, Protocol.request("close-final", "close", %{}))
    state
  end

  defp maybe_send_close_frame(_state), do: :ok

  defp cleanup_pending_requests(pending_requests) do
    Enum.each(pending_requests, fn {_id, from} ->
      GenServer.reply(from, transport_error(Error.transport_stopped()))
    end)
  end

  defp demonitor_subscribers(subscribers) do
    Enum.each(subscribers, fn {_pid, %{monitor_ref: ref}} ->
      Process.demonitor(ref, [:flush])
    end)
  end

  defp disconnect(state, status) do
    cleanup_pending_requests(state.pending_requests)
    %{state | status: status, pending_requests: %{}, socket: nil}
  end

  defp transport_info(state) do
    %Info{
      invocation: state.invocation,
      pid: self(),
      os_pid: nil,
      surface_kind: state.surface_kind,
      target_id: state.target_id,
      lease_ref: state.lease_ref,
      surface_ref: state.surface_ref,
      boundary_class: state.boundary_class,
      observability: state.observability,
      adapter_capabilities: state.adapter_capabilities,
      effective_capabilities: state.effective_capabilities,
      bridge_profile: state.bridge_profile,
      protocol_version: state.protocol_version,
      extensions: state.extensions,
      adapter_metadata: state.adapter_metadata,
      status: state.status,
      stdout_mode: state.stdout_mode,
      stdin_mode: state.stdin_mode,
      pty?: state.pty?,
      interrupt_mode: state.interrupt_mode,
      stderr: state.stderr_buffer,
      delivery: Transport.Delivery.new(state.event_tag)
    }
  end

  defp build_invocation(%Options{} = options) do
    Command.new(options.command, options.args,
      cwd: options.cwd,
      env: options.env,
      clear_env?: options.clear_env?,
      user: options.user
    )
  end

  defp launch_payload(%Command{} = command, %Capabilities{} = capabilities) do
    %{
      "command" => command.command,
      "args" => command.args
    }
    |> maybe_put("cwd", command.cwd, capabilities.supports_cwd?)
    |> maybe_put("env", command.env, capabilities.supports_env? and map_size(command.env) > 0)
    |> maybe_put(
      "clear_env?",
      command.clear_env?,
      capabilities.supports_env? and command.clear_env?
    )
    |> maybe_put("user", command.user, capabilities.supports_user?)
  end

  defp maybe_put(payload, _key, nil, _enabled), do: payload
  defp maybe_put(payload, _key, _value, false), do: payload
  defp maybe_put(payload, key, value, true), do: Map.put(payload, key, value)

  defp run_result_from_payload(payload, %Command{} = invocation) when is_map(payload) do
    stdout = Map.get(payload, "stdout", "")
    stderr = Map.get(payload, "stderr", "")
    stderr_mode = decode_atomish(Map.get(payload, "stderr_mode", "separate"))

    with {:ok, exit} <- exit_from_payload(Map.get(payload, "exit", %{}), stderr) do
      output = if stderr_mode == :stdout, do: stdout <> stderr, else: stdout

      {:ok,
       %RunResult{
         invocation: invocation,
         output: output,
         stdout: stdout,
         stderr: stderr,
         exit: exit,
         stderr_mode: stderr_mode
       }}
    end
  end

  defp exit_from_payload(payload, stderr) when is_map(payload) do
    status = decode_atomish(Map.get(payload, "status", "error"))

    exit =
      %ProcessExit{
        status: status,
        code: Map.get(payload, "code"),
        signal: decode_atomish(Map.get(payload, "signal")),
        reason: Map.get(payload, "reason"),
        stderr: Map.get(payload, "stderr", stderr)
      }

    {:ok, exit}
  end

  defp exit_from_payload(other, _stderr),
    do: {:error, Error.bridge_protocol_error({:invalid_exit_payload, other})}

  defp fetch_binary(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      value when is_binary(value) -> {:ok, value}
      other -> {:error, {:invalid_field, key, other}}
    end
  end

  defp normalize_payload(message) when is_binary(message), do: message
  defp normalize_payload(message) when is_map(message), do: Jason.encode!(message)

  defp normalize_payload(message) when is_list(message) do
    IO.iodata_to_binary(message)
  rescue
    ArgumentError -> Jason.encode!(message)
  end

  defp normalize_payload(message), do: to_string(message)

  defp maybe_ensure_newline(payload, :line) do
    if String.ends_with?(payload, "\n"), do: payload, else: payload <> "\n"
  end

  defp maybe_ensure_newline(payload, _stdin_mode), do: payload

  defp fetch_option(%Options{} = options, key), do: Map.get(options, key)
  defp fetch_option(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp encode_atomish(nil), do: nil
  defp encode_atomish(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_atomish(value), do: value

  defp decode_atomish(nil), do: nil
  defp decode_atomish(value) when is_atom(value), do: value

  defp decode_atomish(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp decode_atomish(value), do: value

  defp validate_runtime_capability(nil, _capability, _surface_kind),
    do: {:error, Error.not_connected()}

  defp validate_runtime_capability(
         %Capabilities{supports_streaming_stdio?: true},
         :streaming_stdio,
         _surface_kind
       ),
       do: :ok

  defp validate_runtime_capability(_capabilities, capability, surface_kind),
    do: {:error, Error.unsupported_capability(capability, surface_kind)}

  defp normalize_transport_error(reason), do: Error.transport_error(reason)

  defp transport_error(%Error{} = error), do: {:error, {:transport, error}}
  defp transport_error(reason), do: {:error, {:transport, Error.transport_error(reason)}}
end
