defmodule CliSubprocessCore.ProtocolSession do
  @moduledoc """
  Generic protocol-session runtime above `CliSubprocessCore.Channel`.

  The session owns:

  - channel lifecycle
  - readiness state
  - startup timeout
  - outbound request tracking
  - inbound peer-request tracking
  - peer-request handler dispatch
  - request timeouts
  - close and interrupt normalization
  """

  use GenServer

  alias CliSubprocessCore.{Channel, TaskSupport}

  @default_request_timeout_ms 30_000
  @default_peer_request_timeout_ms 30_000
  @default_startup_timeout_ms 5_000
  @channel_event_tag :cli_subprocess_core_protocol_session_channel

  @reserved_keys [
    :adapter,
    :adapter_options,
    :startup_requests,
    :startup_notifications,
    :ready_mode,
    :startup_timeout_ms,
    :request_timeout_ms,
    :peer_request_timeout_ms,
    :notification_handler,
    :protocol_error_handler,
    :stderr_handler,
    :peer_request_notifier,
    :peer_request_handler
  ]

  defstruct adapter: nil,
            adapter_state: nil,
            channel: nil,
            channel_ref: nil,
            phase: :starting,
            ready_mode: :immediate,
            startup_timeout_ms: @default_startup_timeout_ms,
            startup_timer_ref: nil,
            request_timeout_ms: @default_request_timeout_ms,
            peer_request_timeout_ms: @default_peer_request_timeout_ms,
            startup_requests: [],
            startup_notifications: [],
            pending_requests: %{},
            startup_pending: MapSet.new(),
            ready_waiters: [],
            peer_requests: %{},
            notification_handler: nil,
            protocol_error_handler: nil,
            stderr_handler: nil,
            peer_request_notifier: nil,
            peer_request_handler: nil

  @type t :: pid()

  @type ready_mode :: :immediate | :startup_complete | :adapter_event

  @type info_t :: %{
          adapter: module(),
          phase: :starting | :ready,
          ready_mode: ready_mode(),
          pending_requests: non_neg_integer(),
          pending_peer_requests: non_neg_integer(),
          channel: map() | %{}
        }

  @doc """
  Starts an unlinked protocol session.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts) when is_list(opts) do
    Application.ensure_all_started(:cli_subprocess_core)
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Starts a linked protocol session.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    Application.ensure_all_started(:cli_subprocess_core)
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Waits for the protocol session to become ready.
  """
  @spec await_ready(pid(), pos_integer()) :: :ok | {:error, term()}
  def await_ready(session, timeout_ms)
      when is_pid(session) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(session, :await_ready, timeout_ms)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, reason}
  end

  @doc """
  Sends an outbound protocol request and waits for the correlated reply.
  """
  @spec request(pid(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(session, request, opts \\ []) when is_pid(session) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_request_timeout_ms)

    if is_integer(timeout_ms) and timeout_ms > 0 do
      GenServer.call(session, {:request, request, timeout_ms}, :infinity)
    else
      {:error, {:invalid_timeout, timeout_ms}}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Sends an outbound protocol notification.
  """
  @spec notify(pid(), term()) :: :ok | {:error, term()}
  def notify(session, notification) when is_pid(session) do
    GenServer.call(session, {:notify, notification})
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Interrupts the underlying channel.
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) when is_pid(session) do
    GenServer.call(session, :interrupt)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Stops the protocol session.
  """
  @spec close(pid()) :: :ok
  def close(session) when is_pid(session) do
    GenServer.stop(session, :normal)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns protocol-session information.
  """
  @spec info(pid()) :: info_t() | %{}
  def info(session) when is_pid(session) do
    GenServer.call(session, :info)
  catch
    :exit, _reason -> %{}
  end

  @impl GenServer
  def init(opts) do
    with {:ok, adapter} <- validate_adapter(Keyword.get(opts, :adapter)),
         {:ok, adapter_state, startup_frames} <-
           adapter.init(Keyword.get(opts, :adapter_options, [])),
         {:ok, ready_mode} <-
           normalize_ready_mode(
             Keyword.get(opts, :ready_mode),
             Keyword.get(opts, :startup_requests, [])
           ),
         {:ok, startup_timeout_ms} <-
           validate_timeout(
             Keyword.get(opts, :startup_timeout_ms, @default_startup_timeout_ms),
             :startup_timeout_ms
           ),
         {:ok, request_timeout_ms} <-
           validate_timeout(
             Keyword.get(opts, :request_timeout_ms, @default_request_timeout_ms),
             :request_timeout_ms
           ),
         {:ok, peer_request_timeout_ms} <-
           validate_timeout(
             Keyword.get(opts, :peer_request_timeout_ms, @default_peer_request_timeout_ms),
             :peer_request_timeout_ms
           ),
         :ok <- validate_handler(Keyword.get(opts, :notification_handler), :notification_handler),
         :ok <-
           validate_handler(Keyword.get(opts, :protocol_error_handler), :protocol_error_handler),
         :ok <- validate_handler(Keyword.get(opts, :stderr_handler), :stderr_handler),
         :ok <-
           validate_handler(Keyword.get(opts, :peer_request_notifier), :peer_request_notifier, 2),
         :ok <- validate_handler(Keyword.get(opts, :peer_request_handler), :peer_request_handler),
         {:ok, channel, channel_ref} <- start_channel(opts) do
      state = %__MODULE__{
        adapter: adapter,
        adapter_state: adapter_state,
        channel: channel,
        channel_ref: channel_ref,
        phase: :starting,
        ready_mode: ready_mode,
        startup_timeout_ms: startup_timeout_ms,
        request_timeout_ms: request_timeout_ms,
        peer_request_timeout_ms: peer_request_timeout_ms,
        startup_requests: Keyword.get(opts, :startup_requests, []),
        startup_notifications: Keyword.get(opts, :startup_notifications, []),
        pending_requests: %{},
        startup_pending: MapSet.new(),
        ready_waiters: [],
        peer_requests: %{},
        notification_handler: Keyword.get(opts, :notification_handler),
        protocol_error_handler: Keyword.get(opts, :protocol_error_handler),
        stderr_handler: Keyword.get(opts, :stderr_handler),
        peer_request_notifier: Keyword.get(opts, :peer_request_notifier),
        peer_request_handler: Keyword.get(opts, :peer_request_handler)
      }

      {:ok, state, {:continue, {:boot, startup_frames}}}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue({:boot, startup_frames}, state) do
    with {:ok, state} <- send_startup_frames(state, startup_frames),
         {:ok, state} <- send_startup_notifications(state),
         {:ok, state} <- send_startup_requests(state) do
      state =
        state
        |> maybe_start_startup_timer()
        |> maybe_mark_ready_after_boot()

      {:noreply, state}
    else
      {:error, reason, next_state} ->
        {:stop, reason, next_state}
    end
  end

  @impl GenServer
  def handle_call(:await_ready, _from, %{phase: :ready} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_ready, from, state) do
    {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
  end

  def handle_call({:request, _request, _timeout_ms}, _from, %{phase: phase} = state)
      when phase != :ready do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:request, request, timeout_ms}, from, state) do
    case encode_request(state, request, from, timeout_ms, false) do
      {:ok, next_state} -> {:noreply, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:notify, notification}, _from, state) do
    case encode_notification(state, notification) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, Channel.interrupt(state.channel), state}
  end

  def handle_call(:info, _from, state) do
    {:reply, session_info(state), state}
  end

  @impl GenServer
  def handle_info(message, %{channel_ref: channel_ref} = state) do
    case Channel.extract_event(message, channel_ref) do
      {:ok, {:message, frame}} ->
        handle_inbound_frame(frame, state)

      {:ok, {:data, frame}} ->
        handle_inbound_frame(frame, state)

      {:ok, {:stderr, chunk}} ->
        safe_invoke_handler(state.stderr_handler, chunk)
        {:noreply, state}

      {:ok, {:error, reason}} ->
        {:stop, {:channel_error, reason}, fail_pending(state, {:channel_error, reason})}

      {:ok, {:exit, exit}} ->
        {:stop, {:channel_exit, exit}, fail_pending(state, {:channel_exit, exit})}

      :error ->
        handle_other_info(message, state)
    end
  end

  defp handle_other_info({:request_timeout, correlation_key}, state) do
    case Map.pop(state.pending_requests, correlation_key) do
      {nil, _rest} ->
        {:noreply, state}

      {%{from: from, timer_ref: timer_ref, startup?: startup?, request: request}, rest} ->
        _ = Process.cancel_timer(timer_ref)

        next_state = %{
          state
          | pending_requests: rest,
            startup_pending: MapSet.delete(state.startup_pending, correlation_key)
        }

        if startup? do
          {:stop, {:startup_timeout, request},
           fail_ready(next_state, {:startup_timeout, request})}
        else
          GenServer.reply(from, {:error, :timeout})
          {:noreply, next_state}
        end
    end
  end

  defp handle_other_info(:startup_timeout, state) do
    {:stop, :startup_timeout, fail_ready(state, :startup_timeout)}
  end

  defp handle_other_info({:peer_request_timeout, task_ref}, state) do
    case Map.pop(state.peer_requests, task_ref) do
      {nil, _rest} ->
        {:noreply, state}

      {%{task: task, timer_ref: timer_ref, correlation_key: correlation_key}, rest} ->
        _ = Process.cancel_timer(timer_ref)
        _ = Task.shutdown(task, :brutal_kill)
        Process.demonitor(task.ref, [:flush])

        case send_peer_reply(%{state | peer_requests: rest}, correlation_key, {:error, :timeout}) do
          {:ok, next_state} -> {:noreply, next_state}
          {:error, reason, next_state} -> {:stop, reason, next_state}
        end
    end
  end

  defp handle_other_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.peer_requests, task_ref) do
      {nil, _rest} ->
        {:noreply, state}

      {%{task: task, timer_ref: timer_ref, correlation_key: correlation_key}, rest} ->
        _ = Process.cancel_timer(timer_ref)
        Process.demonitor(task.ref, [:flush])

        case send_peer_reply(
               %{state | peer_requests: rest},
               correlation_key,
               normalize_peer_handler_result(result)
             ) do
          {:ok, next_state} -> {:noreply, next_state}
          {:error, reason, next_state} -> {:stop, reason, next_state}
        end
    end
  end

  defp handle_other_info({:DOWN, task_ref, :process, _pid, reason}, state)
       when is_reference(task_ref) do
    case Map.pop(state.peer_requests, task_ref) do
      {nil, _rest} ->
        {:noreply, state}

      {%{timer_ref: timer_ref, correlation_key: correlation_key}, rest} ->
        _ = Process.cancel_timer(timer_ref)

        case send_peer_reply(
               %{state | peer_requests: rest},
               correlation_key,
               {:error, {:handler_exit, reason}}
             ) do
          {:ok, next_state} -> {:noreply, next_state}
          {:error, stop_reason, next_state} -> {:stop, stop_reason, next_state}
        end
    end
  end

  defp handle_other_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    fail_waiters(state.ready_waiters, {:error, :closed})
    fail_request_callers(state.pending_requests, {:error, :closed})
    cancel_peer_request_timers(state.peer_requests)
    cancel_startup_timer(state.startup_timer_ref)
    _ = Channel.close(state.channel)
    :ok
  catch
    _, _ -> :ok
  end

  defp handle_inbound_frame(frame, state) when is_binary(frame) do
    case state.adapter.handle_inbound(frame, state.adapter_state) do
      {:ok, events, adapter_state} ->
        process_inbound_events(events, %{state | adapter_state: adapter_state})

      {:error, reason} ->
        {:stop, {:adapter_error, reason}, fail_pending(state, {:adapter_error, reason})}
    end
  end

  defp process_inbound_events([], state), do: {:noreply, state}

  defp process_inbound_events([event | rest], state) do
    case process_inbound_event(event, state) do
      {:ok, next_state} ->
        process_inbound_events(rest, next_state)

      {:stop, reason, next_state} ->
        {:stop, reason, next_state}
    end
  end

  defp process_inbound_event(:ignore, state), do: {:ok, state}

  defp process_inbound_event({:notification, notification}, state) do
    safe_invoke_handler(state.notification_handler, notification)
    {:ok, state}
  end

  defp process_inbound_event({:protocol_error, reason}, state) do
    safe_invoke_handler(state.protocol_error_handler, reason)
    {:ok, state}
  end

  defp process_inbound_event({:fatal_protocol_error, reason}, state) do
    {:stop, {:fatal_protocol_error, reason}, fail_pending(state, {:fatal_protocol_error, reason})}
  end

  defp process_inbound_event({:ready, _details}, state) do
    {:ok, mark_ready(state)}
  end

  defp process_inbound_event({:response, correlation_key, outcome}, state) do
    case Map.pop(state.pending_requests, correlation_key) do
      {nil, _rest} ->
        safe_invoke_handler(
          state.protocol_error_handler,
          {:unexpected_response, correlation_key, outcome}
        )

        {:ok, state}

      {%{from: from, timer_ref: timer_ref, startup?: startup?, request: request}, rest} ->
        _ = Process.cancel_timer(timer_ref)

        next_state = %{
          state
          | pending_requests: rest,
            startup_pending: MapSet.delete(state.startup_pending, correlation_key)
        }

        cond do
          startup? and match?({:error, _}, outcome) ->
            {:stop, {:startup_request_failed, request, outcome},
             fail_ready(next_state, {:startup_request_failed, request, outcome})}

          startup? ->
            {:ok, maybe_mark_ready_after_startup_response(next_state)}

          true ->
            GenServer.reply(from, outcome)
            {:ok, next_state}
        end
    end
  end

  defp process_inbound_event({:peer_request, correlation_key, request}, state) do
    safe_invoke_handler(state.peer_request_notifier, correlation_key, request)
    {:ok, dispatch_peer_request(state, correlation_key, request)}
  end

  defp send_startup_frames(state, frames) when is_list(frames) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, acc} ->
      case Channel.send_input(acc.channel, frame) do
        :ok -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:startup_send_failed, reason}, acc}}
      end
    end)
  end

  defp send_startup_notifications(state) do
    Enum.reduce_while(state.startup_notifications, {:ok, state}, fn notification, {:ok, acc} ->
      case encode_notification(acc, notification) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason, next_state} -> {:halt, {:error, reason, next_state}}
      end
    end)
  end

  defp send_startup_requests(state) do
    Enum.reduce_while(state.startup_requests, {:ok, state}, fn request, {:ok, acc} ->
      case encode_request(acc, request, nil, acc.startup_timeout_ms, true) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason, next_state} -> {:halt, {:error, reason, next_state}}
      end
    end)
  end

  defp encode_request(state, request, from, timeout_ms, startup?) do
    with {:ok, correlation_key, frame, adapter_state} <-
           state.adapter.encode_request(request, state.adapter_state),
         :ok <- Channel.send_input(state.channel, frame) do
      timer_ref = Process.send_after(self(), {:request_timeout, correlation_key}, timeout_ms)

      next_state = %{
        state
        | adapter_state: adapter_state,
          pending_requests:
            Map.put(state.pending_requests, correlation_key, %{
              from: from,
              request: request,
              startup?: startup?,
              timer_ref: timer_ref
            }),
          startup_pending:
            if(startup?,
              do: MapSet.put(state.startup_pending, correlation_key),
              else: state.startup_pending
            )
      }

      {:ok, next_state}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp encode_notification(state, notification) do
    with {:ok, frame, adapter_state} <-
           state.adapter.encode_notification(notification, state.adapter_state),
         :ok <- Channel.send_input(state.channel, frame) do
      {:ok, %{state | adapter_state: adapter_state}}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp dispatch_peer_request(state, correlation_key, request) do
    handler = state.peer_request_handler || fn _request -> {:error, :unsupported_peer_request} end

    case TaskSupport.async_nolink(fn -> invoke_peer_request_handler(handler, request) end) do
      {:ok, task} ->
        timer_ref =
          Process.send_after(
            self(),
            {:peer_request_timeout, task.ref},
            state.peer_request_timeout_ms
          )

        %{
          state
          | peer_requests:
              Map.put(state.peer_requests, task.ref, %{
                task: task,
                timer_ref: timer_ref,
                correlation_key: correlation_key
              })
        }

      {:error, reason} ->
        case send_peer_reply(state, correlation_key, {:error, {:handler_start_failed, reason}}) do
          {:ok, next_state} -> next_state
          {:error, _stop_reason, next_state} -> next_state
        end
    end
  end

  defp invoke_peer_request_handler(handler, request) do
    case handler.(request) do
      {:ok, _result} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:ok, other}
    end
  end

  defp normalize_peer_handler_result({:ok, _result} = ok), do: ok
  defp normalize_peer_handler_result({:error, _reason} = error), do: error
  defp normalize_peer_handler_result(other), do: {:ok, other}

  defp send_peer_reply(state, correlation_key, result) do
    with {:ok, frame, adapter_state} <-
           state.adapter.encode_peer_reply(correlation_key, result, state.adapter_state),
         :ok <- Channel.send_input(state.channel, frame) do
      {:ok, %{state | adapter_state: adapter_state}}
    else
      {:error, reason} ->
        {:error, {:peer_reply_failed, reason}, fail_pending(state, {:peer_reply_failed, reason})}
    end
  end

  defp maybe_start_startup_timer(%{phase: :ready} = state), do: state

  defp maybe_start_startup_timer(%{startup_timer_ref: timer_ref} = state)
       when is_reference(timer_ref),
       do: state

  defp maybe_start_startup_timer(state) do
    timer_ref = Process.send_after(self(), :startup_timeout, state.startup_timeout_ms)
    %{state | startup_timer_ref: timer_ref}
  end

  defp maybe_mark_ready_after_boot(%{ready_mode: :immediate} = state) do
    mark_ready(state)
  end

  defp maybe_mark_ready_after_boot(
         %{ready_mode: :startup_complete, startup_pending: pending} = state
       ) do
    if MapSet.size(pending) == 0 do
      mark_ready(state)
    else
      state
    end
  end

  defp maybe_mark_ready_after_boot(state), do: state

  defp maybe_mark_ready_after_startup_response(
         %{ready_mode: :startup_complete, startup_pending: pending} = state
       ) do
    if MapSet.size(pending) == 0 do
      mark_ready(state)
    else
      state
    end
  end

  defp maybe_mark_ready_after_startup_response(state), do: state

  defp mark_ready(%{phase: :ready} = state), do: state

  defp mark_ready(state) do
    cancel_startup_timer(state.startup_timer_ref)
    fail_waiters(state.ready_waiters, :ok)
    %{state | phase: :ready, ready_waiters: [], startup_timer_ref: nil}
  end

  defp fail_ready(state, reason) do
    cancel_startup_timer(state.startup_timer_ref)
    fail_waiters(state.ready_waiters, {:error, reason})
    %{state | ready_waiters: [], startup_timer_ref: nil}
  end

  defp fail_pending(state, reason) do
    state
    |> fail_ready(reason)
    |> then(fn next_state ->
      fail_request_callers(next_state.pending_requests, {:error, reason})
      cancel_request_timers(next_state.pending_requests)
      cancel_peer_request_timers(next_state.peer_requests)
      %{next_state | pending_requests: %{}, startup_pending: MapSet.new(), peer_requests: %{}}
    end)
  end

  defp fail_waiters(waiters, reply) do
    Enum.each(waiters, fn waiter ->
      GenServer.reply(waiter, reply)
    end)
  end

  defp fail_request_callers(pending_requests, reply) do
    Enum.each(pending_requests, fn
      {_key, %{from: nil}} ->
        :ok

      {_key, %{from: from}} ->
        GenServer.reply(from, reply)
    end)
  end

  defp cancel_request_timers(pending_requests) do
    Enum.each(pending_requests, fn {_key, %{timer_ref: timer_ref}} ->
      _ = Process.cancel_timer(timer_ref)
    end)
  end

  defp cancel_peer_request_timers(peer_requests) do
    Enum.each(peer_requests, fn {_ref, %{task: task, timer_ref: timer_ref}} ->
      _ = Process.cancel_timer(timer_ref)
      _ = Task.shutdown(task, :brutal_kill)
      Process.demonitor(task.ref, [:flush])
    end)
  end

  defp cancel_startup_timer(nil), do: :ok
  defp cancel_startup_timer(timer_ref), do: Process.cancel_timer(timer_ref)

  defp session_info(state) do
    %{
      adapter: state.adapter,
      phase: state.phase,
      ready_mode: state.ready_mode,
      pending_requests: map_size(state.pending_requests),
      pending_peer_requests: map_size(state.peer_requests),
      channel: Channel.info(state.channel)
    }
  end

  defp start_channel(opts) do
    channel_ref = make_ref()

    channel_opts =
      opts
      |> Keyword.drop(@reserved_keys)
      |> Keyword.put(:subscriber, {self(), channel_ref})
      |> Keyword.put(:channel_event_tag, @channel_event_tag)
      |> Keyword.put_new(:stdout_mode, :line)
      |> Keyword.put_new(:stdin_mode, :raw)

    case Channel.start(channel_opts) do
      {:ok, channel} -> {:ok, channel, channel_ref}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :init, 1) do
      {:ok, adapter}
    else
      {:error, {:invalid_adapter, adapter}}
    end
  end

  defp validate_adapter(adapter), do: {:error, {:invalid_adapter, adapter}}

  defp validate_timeout(timeout_ms, _label) when is_integer(timeout_ms) and timeout_ms > 0,
    do: {:ok, timeout_ms}

  defp validate_timeout(timeout_ms, label), do: {:error, {label, timeout_ms}}

  defp validate_handler(handler, label), do: validate_handler(handler, label, 1)

  defp validate_handler(nil, _label, _arity), do: :ok
  defp validate_handler(handler, _label, arity) when is_function(handler, arity), do: :ok
  defp validate_handler(handler, label, _arity), do: {:error, {label, handler}}

  defp normalize_ready_mode(nil, startup_requests) when is_list(startup_requests) do
    if startup_requests == [], do: {:ok, :immediate}, else: {:ok, :startup_complete}
  end

  defp normalize_ready_mode(mode, _startup_requests)
       when mode in [:immediate, :startup_complete, :adapter_event],
       do: {:ok, mode}

  defp normalize_ready_mode(mode, _startup_requests), do: {:error, {:invalid_ready_mode, mode}}

  defp safe_invoke_handler(nil, _value), do: :ok

  defp safe_invoke_handler(handler, value) when is_function(handler, 1) do
    handler.(value)
    :ok
  catch
    _, _ -> :ok
  end

  defp safe_invoke_handler(nil, _value, _other), do: :ok

  defp safe_invoke_handler(handler, value, other) when is_function(handler, 2) do
    handler.(value, other)
    :ok
  catch
    _, _ -> :ok
  end
end
