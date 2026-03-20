defmodule CliSubprocessCore.Transport.Erlexec do
  @moduledoc """
  `erlexec`-backed raw subprocess transport.

  This implementation owns subprocess startup, stdout line framing, realtime
  stderr dispatch, subscriber fan-out, bounded call behavior, and final exit
  flushing for late stdout/stderr fragments.
  """

  use GenServer

  import Kernel, except: [send: 2]

  alias CliSubprocessCore.{
    LineFraming,
    ProcessExit,
    TaskSupport,
    Transport,
    Transport.Error,
    Transport.Options
  }

  @behaviour Transport

  @default_call_timeout_ms 5_000
  @default_force_close_timeout_ms 5_000
  @default_finalize_delay_ms 25
  @default_max_lines_per_batch 200
  @exec_wait_attempts 20
  @exec_wait_delay_ms 50

  defstruct subprocess: nil,
            subscribers: %{},
            stdout_framer: %LineFraming{},
            pending_lines: :queue.new(),
            drain_scheduled?: false,
            status: :disconnected,
            stderr_buffer: "",
            stderr_framer: %LineFraming{},
            max_buffer_size: nil,
            max_stderr_buffer_size: nil,
            overflowed?: false,
            pending_calls: %{},
            finalize_timer_ref: nil,
            headless_timeout_ms: nil,
            headless_timer_ref: nil,
            task_supervisor: nil,
            event_tag: nil,
            stderr_callback: nil,
            startup_options: nil

  @type subscriber_info :: %{
          monitor_ref: reference(),
          tag: Transport.subscription_tag()
        }

  @impl Transport
  def start(opts) when is_list(opts) do
    case Options.new(opts) do
      {:ok, options} ->
        case GenServer.start(__MODULE__, options) do
          {:ok, pid} -> {:ok, pid}
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
  def send(transport, message) when is_pid(transport) do
    case safe_call(transport, {:send, message}) do
      {:ok, result} -> result
      {:error, reason} -> transport_error(reason)
    end
  end

  @impl Transport
  def subscribe(transport, pid) when is_pid(transport) and is_pid(pid) do
    subscribe(transport, pid, :legacy)
  end

  @impl Transport
  def subscribe(transport, pid, tag)
      when is_pid(transport) and is_pid(pid) and (tag == :legacy or is_reference(tag)) do
    case safe_call(transport, {:subscribe, pid, tag}) do
      {:ok, result} -> result
      {:error, reason} -> transport_error(reason)
    end
  end

  def subscribe(_transport, _pid, tag) do
    transport_error(Error.invalid_options({:invalid_subscriber, tag}))
  end

  @impl Transport
  def unsubscribe(transport, pid) when is_pid(transport) and is_pid(pid) do
    case safe_call(transport, {:unsubscribe, pid}) do
      {:ok, :ok} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @impl Transport
  def close(transport) when is_pid(transport) do
    GenServer.stop(transport, :normal)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, :noproc -> :ok
  end

  @impl Transport
  def force_close(transport) when is_pid(transport) do
    case safe_call(transport, :force_close, @default_force_close_timeout_ms) do
      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        transport_error(reason)
    end
  end

  @impl Transport
  def interrupt(transport) when is_pid(transport) do
    case safe_call(transport, :interrupt) do
      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        transport_error(reason)
    end
  end

  @impl Transport
  def status(transport) when is_pid(transport) do
    case safe_call(transport, :status) do
      {:ok, status} when status in [:connected, :disconnected, :error] -> status
      {:ok, _other} -> :error
      {:error, _reason} -> :disconnected
    end
  end

  @impl Transport
  def end_input(transport) when is_pid(transport) do
    case safe_call(transport, :end_input) do
      {:ok, result} -> result
      {:error, reason} -> transport_error(reason)
    end
  end

  @impl Transport
  def stderr(transport) when is_pid(transport) do
    case safe_call(transport, :stderr) do
      {:ok, data} when is_binary(data) -> data
      _ -> ""
    end
  end

  @impl GenServer
  def init(%Options{} = options) do
    state = build_state(options)

    case options.startup_mode do
      :lazy ->
        {:ok, maybe_schedule_headless_timer(state), {:continue, :start_subprocess}}

      :eager ->
        case start_subprocess(state, options) do
          {:ok, connected_state} -> {:ok, connected_state}
          {:error, reason} -> {:stop, reason}
        end
    end
  end

  @impl GenServer
  def handle_continue(:start_subprocess, %{startup_options: %Options{} = options} = state) do
    case start_subprocess(state, options) do
      {:ok, connected_state} ->
        {:noreply, connected_state}

      {:error, reason} ->
        {:stop, reason, %{state | startup_options: nil}}
    end
  end

  @impl GenServer
  def handle_call({:subscribe, pid, tag}, _from, state) do
    {:reply, :ok, put_subscriber(state, pid, tag)}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, remove_subscriber(state, pid)}
  end

  def handle_call({:send, message}, from, %{subprocess: {pid, _os_pid}} = state) do
    case start_io_task(state, fn -> send_payload(pid, message) end) do
      {:ok, task} ->
        {:noreply, put_pending_call(state, task.ref, from)}

      {:error, reason} ->
        {:reply, transport_error(reason), state}
    end
  end

  def handle_call({:send, _message}, _from, state) do
    {:reply, transport_error(Error.not_connected()), state}
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:stderr, _from, state), do: {:reply, state.stderr_buffer, state}

  def handle_call(:end_input, from, %{subprocess: {pid, _os_pid}} = state) do
    case start_io_task(state, fn -> send_eof(pid) end) do
      {:ok, task} ->
        {:noreply, put_pending_call(state, task.ref, from)}

      {:error, reason} ->
        {:reply, transport_error(reason), state}
    end
  end

  def handle_call(:end_input, _from, state) do
    {:reply, transport_error(Error.not_connected()), state}
  end

  def handle_call(:interrupt, from, %{subprocess: {_pid, os_pid}} = state) do
    case start_io_task(state, fn -> interrupt_subprocess(os_pid) end) do
      {:ok, task} ->
        {:noreply, put_pending_call(state, task.ref, from)}

      {:error, reason} ->
        {:reply, transport_error(reason), state}
    end
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, transport_error(Error.not_connected()), state}
  end

  def handle_call(:force_close, _from, state) do
    state = force_stop_subprocess(state)
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def handle_info({:stdout, os_pid, chunk}, %{subprocess: {_pid, os_pid}} = state) do
    state =
      state
      |> append_stdout_data(IO.iodata_to_binary(chunk))
      |> drain_stdout_lines(@default_max_lines_per_batch)
      |> maybe_schedule_drain()

    {:noreply, state}
  end

  def handle_info({:stderr, os_pid, chunk}, %{subprocess: {_pid, os_pid}} = state) do
    data = IO.iodata_to_binary(chunk)
    stderr_buffer = append_stderr_data(state.stderr_buffer, data, state.max_stderr_buffer_size)
    {stderr_lines, stderr_framer} = LineFraming.push(state.stderr_framer, data)

    dispatch_stderr_callback(state.stderr_callback, stderr_lines)
    send_event(state.subscribers, {:stderr, data}, state.event_tag)

    {:noreply, %{state | stderr_buffer: stderr_buffer, stderr_framer: stderr_framer}}
  end

  def handle_info({ref, result}, %{pending_calls: pending_calls} = state)
      when is_reference(ref) do
    case Map.pop(pending_calls, ref) do
      {nil, _rest} ->
        {:noreply, state}

      {from, rest} ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, normalize_call_result(result))
        {:noreply, %{state | pending_calls: rest}}
    end
  end

  def handle_info({:DOWN, os_pid, :process, pid, reason}, %{subprocess: {pid, os_pid}} = state) do
    state = cancel_finalize_timer(state)

    timer_ref =
      Process.send_after(
        self(),
        {:finalize_exit, os_pid, pid, reason},
        @default_finalize_delay_ms
      )

    {:noreply, %{state | finalize_timer_ref: timer_ref}}
  end

  def handle_info({:finalize_exit, os_pid, pid, reason}, %{subprocess: {pid, os_pid}} = state) do
    state =
      state
      |> Map.put(:finalize_timer_ref, nil)
      |> Map.put(:drain_scheduled?, false)
      |> drain_stdout_lines(@default_max_lines_per_batch)

    if :queue.is_empty(state.pending_lines) do
      state = flush_stdout_fragment(state)
      state = flush_stderr_fragment(state)
      send_event(state.subscribers, {:exit, ProcessExit.from_reason(reason)}, state.event_tag)
      {:stop, :normal, %{state | status: :disconnected, subprocess: nil}}
    else
      Kernel.send(self(), {:finalize_exit, os_pid, pid, reason})
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{pending_calls: pending_calls} = state)
      when is_reference(ref) do
    case Map.pop(pending_calls, ref) do
      {from, rest} when not is_nil(from) ->
        GenServer.reply(from, transport_error(Error.send_failed(reason)))
        {:noreply, %{state | pending_calls: rest}}

      {nil, _rest} ->
        {:noreply, handle_subscriber_down(ref, pid, state)}
    end
  end

  def handle_info(:drain_stdout, state) do
    state =
      state
      |> Map.put(:drain_scheduled?, false)
      |> drain_stdout_lines(@default_max_lines_per_batch)
      |> maybe_schedule_drain()

    {:noreply, state}
  end

  def handle_info(:headless_timeout, state) do
    state = %{state | headless_timer_ref: nil}

    if map_size(state.subscribers) == 0 and not is_nil(state.subprocess) do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    state =
      state
      |> cancel_finalize_timer()
      |> cancel_headless_timer()

    demonitor_subscribers(state.subscribers)
    cleanup_pending_calls(state.pending_calls)
    _ = force_stop_subprocess(state)
    :ok
  catch
    _, _ -> :ok
  end

  defp build_state(%Options{} = options) do
    %__MODULE__{
      status: :disconnected,
      max_buffer_size: options.max_buffer_size,
      max_stderr_buffer_size: options.max_stderr_buffer_size,
      headless_timeout_ms: options.headless_timeout_ms,
      task_supervisor: options.task_supervisor,
      event_tag: options.event_tag,
      stderr_callback: options.stderr_callback,
      startup_options: options
    }
  end

  defp safe_call(transport, message, timeout \\ @default_call_timeout_ms)

  defp safe_call(transport, message, timeout)
       when is_pid(transport) and is_integer(timeout) and timeout >= 0 do
    case TaskSupport.async_nolink(fn ->
           try do
             {:ok, GenServer.call(transport, message, :infinity)}
           catch
             :exit, reason -> {:error, normalize_call_exit(reason)}
           end
         end) do
      {:ok, task} ->
        await_task_result(task, timeout)

      {:error, reason} ->
        {:error, normalize_call_task_start_error(reason)}
    end
  end

  defp await_task_result(task, timeout) do
    case TaskSupport.await(task, timeout, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, normalize_call_exit(reason)}
      {:error, :timeout} -> {:error, Error.timeout()}
    end
  end

  defp normalize_call_task_start_error(:noproc), do: Error.transport_stopped()
  defp normalize_call_task_start_error(reason), do: Error.call_exit(reason)

  defp normalize_call_exit({:noproc, _}), do: Error.not_connected()
  defp normalize_call_exit(:noproc), do: Error.not_connected()
  defp normalize_call_exit({:normal, _}), do: Error.not_connected()
  defp normalize_call_exit({:shutdown, _}), do: Error.not_connected()
  defp normalize_call_exit({:timeout, _}), do: Error.timeout()
  defp normalize_call_exit(reason), do: Error.call_exit(reason)

  defp normalize_call_result(:ok), do: :ok
  defp normalize_call_result({:error, {:transport, %Error{}}} = error), do: error
  defp normalize_call_result({:error, %Error{} = error}), do: transport_error(error)
  defp normalize_call_result({:error, reason}), do: transport_error(reason)

  defp normalize_call_result(other),
    do: transport_error(Error.transport_error({:unexpected_task_result, other}))

  defp start_subprocess(state, %Options{} = options) do
    with :ok <- validate_cwd_exists(options.cwd),
         :ok <- validate_command_exists(options.command),
         :ok <- ensure_erlexec_started(),
         exec_opts <- build_exec_opts(options),
         argv <- normalize_command_argv(options.command, options.args),
         {:ok, pid, os_pid} <- exec_run(options.command, argv, exec_opts),
         {:ok, state} <-
           add_bootstrap_subscriber(connected_state(state, pid, os_pid), options.subscriber) do
      {:ok, maybe_schedule_headless_timer(%{state | startup_options: nil})}
    end
  end

  defp validate_cwd_exists(nil), do: :ok

  defp validate_cwd_exists(cwd) when is_binary(cwd) do
    if File.dir?(cwd) do
      :ok
    else
      {:error, Error.cwd_not_found(cwd)}
    end
  end

  defp validate_command_exists(command) when is_binary(command) do
    cond do
      String.trim(command) == "" ->
        {:error, Error.command_not_found(command)}

      String.contains?(command, "/") ->
        if File.exists?(command), do: :ok, else: {:error, Error.command_not_found(command)}

      is_nil(System.find_executable(command)) ->
        {:error, Error.command_not_found(command)}

      true ->
        :ok
    end
  end

  defp ensure_erlexec_started do
    with :ok <- ensure_erlexec_application_started(),
         :ok <- ensure_exec_worker() do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.startup_failed(reason)}
    end
  end

  defp ensure_erlexec_application_started do
    case Application.ensure_all_started(:erlexec) do
      {:ok, _started_apps} -> :ok
      {:error, {:already_started, _app}} -> :ok
      {:error, {:erlexec, {:already_started, _app}}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_exec_worker do
    case wait_for_exec_worker(@exec_wait_attempts) do
      :ok -> :ok
      :error -> recover_missing_exec_worker()
    end
  end

  defp wait_for_exec_worker(0) do
    if exec_worker_alive?(), do: :ok, else: :error
  end

  defp wait_for_exec_worker(attempts_remaining) when attempts_remaining > 0 do
    if exec_worker_alive?() do
      :ok
    else
      Process.sleep(@exec_wait_delay_ms)
      wait_for_exec_worker(attempts_remaining - 1)
    end
  end

  defp recover_missing_exec_worker do
    if exec_app_alive?() do
      {:error, :exec_not_running}
    else
      with :ok <- restart_erlexec_application(),
           :ok <- wait_for_exec_worker(@exec_wait_attempts) do
        :ok
      else
        :error -> {:error, :exec_not_running}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp restart_erlexec_application do
    case Application.stop(:erlexec) do
      :ok -> ensure_erlexec_application_started()
      {:error, {:not_started, :erlexec}} -> ensure_erlexec_application_started()
      {:error, {:not_started, _app}} -> ensure_erlexec_application_started()
      {:error, reason} -> {:error, reason}
    end
  end

  defp exec_worker_alive? do
    case Process.whereis(:exec) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _other -> false
    end
  end

  defp exec_app_alive? do
    case Process.whereis(:exec_app) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _other -> false
    end
  end

  defp build_exec_opts(%Options{} = options) do
    []
    |> maybe_put_cwd(options.cwd)
    |> maybe_put_env(options.env)
    # Put each subprocess in its own process group so control signals and
    # force-close behavior reach shell wrappers and their active children.
    |> Kernel.++([{:group, 0}, :kill_group, :stdin, :stdout, :stderr, :monitor])
  end

  defp maybe_put_cwd(opts, nil), do: opts
  defp maybe_put_cwd(opts, cwd), do: [{:cd, to_charlist(cwd)} | opts]

  defp maybe_put_env(opts, env) when map_size(env) == 0, do: opts

  defp maybe_put_env(opts, env) do
    [{:env, Enum.map(env, fn {key, value} -> {key, value} end)} | opts]
  end

  defp normalize_command_argv(command, args) when is_binary(command) and is_list(args) do
    [command | args] |> Enum.map(&to_charlist/1)
  end

  defp exec_run(command, argv, exec_opts) do
    case :exec.run(argv, exec_opts) do
      {:ok, pid, os_pid} ->
        {:ok, pid, os_pid}

      {:error, reason} when reason in [:enoent, :eacces] ->
        {:error, Error.command_not_found(command, reason)}

      {:error, reason} ->
        {:error, Error.startup_failed(reason)}
    end
  end

  defp connected_state(state, pid, os_pid) do
    %{state | subprocess: {pid, os_pid}, status: :connected}
  end

  defp add_bootstrap_subscriber(state, nil), do: {:ok, state}

  defp add_bootstrap_subscriber(state, pid) when is_pid(pid),
    do: {:ok, put_subscriber(state, pid, :legacy)}

  defp add_bootstrap_subscriber(state, {pid, tag})
       when is_pid(pid) and (tag == :legacy or is_reference(tag)) do
    {:ok, put_subscriber(state, pid, tag)}
  end

  defp add_bootstrap_subscriber(_state, subscriber) do
    {:error, Error.invalid_options({:invalid_subscriber, subscriber})}
  end

  defp put_subscriber(state, pid, tag) do
    subscribers =
      case Map.fetch(state.subscribers, pid) do
        {:ok, %{monitor_ref: monitor_ref}} ->
          Map.put(state.subscribers, pid, %{monitor_ref: monitor_ref, tag: tag})

        :error ->
          monitor_ref = Process.monitor(pid)
          Map.put(state.subscribers, pid, %{monitor_ref: monitor_ref, tag: tag})
      end

    %{state | subscribers: subscribers}
    |> cancel_headless_timer()
  end

  defp remove_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {%{monitor_ref: monitor_ref}, subscribers} ->
        Process.demonitor(monitor_ref, [:flush])

        %{state | subscribers: subscribers}
        |> maybe_schedule_headless_timer()
    end
  end

  defp handle_subscriber_down(ref, pid, state) do
    subscribers =
      case Map.pop(state.subscribers, pid) do
        {%{monitor_ref: ^ref}, rest} -> rest
        {_value, rest} -> rest
      end

    %{state | subscribers: subscribers}
    |> maybe_schedule_headless_timer()
  end

  defp maybe_schedule_headless_timer(%{headless_timer_ref: ref} = state) when not is_nil(ref),
    do: state

  defp maybe_schedule_headless_timer(%{subscribers: subscribers} = state)
       when map_size(subscribers) > 0,
       do: state

  defp maybe_schedule_headless_timer(%{headless_timeout_ms: :infinity} = state), do: state

  defp maybe_schedule_headless_timer(%{headless_timeout_ms: timeout_ms} = state)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    timer_ref = Process.send_after(self(), :headless_timeout, timeout_ms)
    %{state | headless_timer_ref: timer_ref}
  end

  defp maybe_schedule_headless_timer(state), do: state

  defp cancel_headless_timer(%{headless_timer_ref: nil} = state), do: state

  defp cancel_headless_timer(state) do
    _ = Process.cancel_timer(state.headless_timer_ref, async: false, info: false)
    flush_headless_timeout_message()
    %{state | headless_timer_ref: nil}
  end

  defp flush_headless_timeout_message do
    receive do
      :headless_timeout -> :ok
    after
      0 -> :ok
    end
  end

  defp put_pending_call(state, ref, from) do
    %{state | pending_calls: Map.put(state.pending_calls, ref, from)}
  end

  defp start_io_task(state, fun) when is_function(fun, 0) do
    TaskSupport.async_nolink(state.task_supervisor, fun)
  end

  defp send_payload(pid, message) do
    payload = message |> normalize_payload() |> ensure_newline()
    :exec.send(pid, payload)
    :ok
  catch
    kind, reason ->
      transport_error(Error.send_failed({kind, reason}))
  end

  defp send_eof(pid) do
    :exec.send(pid, :eof)
    :ok
  catch
    kind, reason ->
      transport_error(Error.send_failed({kind, reason}))
  end

  defp interrupt_subprocess(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case System.find_executable("kill") do
      nil ->
        transport_error(Error.send_failed(:kill_command_not_found))

      kill_executable ->
        case System.cmd(kill_executable, ["-INT", "--", "-#{os_pid}"], stderr_to_stdout: true) do
          {_output, 0} ->
            :ok

          {output, status} ->
            transport_error(
              Error.send_failed({:kill_exit_status, status, String.trim_trailing(output)})
            )
        end
    end
  catch
    _, _ ->
      transport_error(Error.not_connected())
  end

  defp send_event(subscribers, event, event_tag) do
    Enum.each(subscribers, fn {pid, info} ->
      dispatch_event(pid, info, event, event_tag)
    end)
  end

  defp dispatch_event(pid, %{tag: :legacy}, {:message, line}, _event_tag),
    do: Kernel.send(pid, {:transport_message, line})

  defp dispatch_event(pid, %{tag: :legacy}, {:error, reason}, _event_tag),
    do: Kernel.send(pid, {:transport_error, reason})

  defp dispatch_event(pid, %{tag: :legacy}, {:stderr, data}, _event_tag),
    do: Kernel.send(pid, {:transport_stderr, data})

  defp dispatch_event(pid, %{tag: :legacy}, {:exit, reason}, _event_tag),
    do: Kernel.send(pid, {:transport_exit, reason})

  defp dispatch_event(pid, %{tag: ref}, event, event_tag) when is_reference(ref),
    do: Kernel.send(pid, {event_tag, ref, event})

  defp append_stdout_data(%{overflowed?: true} = state, data) when is_binary(data) do
    case drop_until_next_newline(data) do
      :none ->
        state

      {:rest, rest} ->
        state
        |> Map.put(:overflowed?, false)
        |> Map.put(:stdout_framer, LineFraming.new())
        |> append_stdout_data(rest)
    end
  end

  defp append_stdout_data(state, data) when is_binary(data) do
    {lines, stdout_framer} = LineFraming.push(state.stdout_framer, data)

    pending_lines =
      Enum.reduce(lines, state.pending_lines, fn line, queue ->
        :queue.in(line, queue)
      end)

    state = %{
      state
      | pending_lines: pending_lines,
        stdout_framer: stdout_framer,
        overflowed?: false
    }

    if byte_size(stdout_framer.buffer) > state.max_buffer_size do
      send_event(
        state.subscribers,
        {:error,
         Error.buffer_overflow(
           byte_size(stdout_framer.buffer),
           state.max_buffer_size,
           preview(stdout_framer.buffer)
         )},
        state.event_tag
      )

      %{state | stdout_framer: LineFraming.new(), overflowed?: true}
    else
      state
    end
  end

  defp drain_stdout_lines(state, 0), do: state

  defp drain_stdout_lines(state, remaining) when is_integer(remaining) and remaining > 0 do
    case :queue.out(state.pending_lines) do
      {:empty, _queue} ->
        state

      {{:value, line}, queue} ->
        state = %{state | pending_lines: queue}

        if byte_size(line) > state.max_buffer_size do
          send_event(
            state.subscribers,
            {:error,
             Error.buffer_overflow(byte_size(line), state.max_buffer_size, preview(line))},
            state.event_tag
          )
        else
          send_event(state.subscribers, {:message, line}, state.event_tag)
        end

        drain_stdout_lines(state, remaining - 1)
    end
  end

  defp maybe_schedule_drain(%{drain_scheduled?: true} = state), do: state

  defp maybe_schedule_drain(state) do
    if :queue.is_empty(state.pending_lines) do
      state
    else
      Kernel.send(self(), :drain_stdout)
      %{state | drain_scheduled?: true}
    end
  end

  defp flush_stdout_fragment(%{stdout_framer: %LineFraming{buffer: ""}} = state) do
    %{state | drain_scheduled?: false}
  end

  defp flush_stdout_fragment(state) do
    {[line], stdout_framer} = LineFraming.flush(state.stdout_framer)

    cond do
      line == "" ->
        %{state | stdout_framer: stdout_framer, overflowed?: false, drain_scheduled?: false}

      byte_size(line) > state.max_buffer_size ->
        send_event(
          state.subscribers,
          {:error, Error.buffer_overflow(byte_size(line), state.max_buffer_size, preview(line))},
          state.event_tag
        )

        %{state | stdout_framer: stdout_framer, overflowed?: false, drain_scheduled?: false}

      true ->
        send_event(state.subscribers, {:message, line}, state.event_tag)
        %{state | stdout_framer: stdout_framer, overflowed?: false, drain_scheduled?: false}
    end
  end

  defp flush_stderr_fragment(%{stderr_framer: %LineFraming{buffer: ""}} = state), do: state

  defp flush_stderr_fragment(state) do
    {lines, stderr_framer} = LineFraming.flush(state.stderr_framer)
    dispatch_stderr_callback(state.stderr_callback, lines)
    %{state | stderr_framer: stderr_framer}
  end

  defp cancel_finalize_timer(%{finalize_timer_ref: nil} = state), do: state

  defp cancel_finalize_timer(state) do
    _ = Process.cancel_timer(state.finalize_timer_ref, async: false, info: false)
    flush_finalize_message(state.subprocess)
    %{state | finalize_timer_ref: nil}
  end

  defp flush_finalize_message({pid, os_pid}) do
    receive do
      {:finalize_exit, ^os_pid, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp flush_finalize_message(_other), do: :ok

  defp append_stderr_data(_existing, _data, max_size)
       when not is_integer(max_size) or max_size <= 0,
       do: ""

  defp append_stderr_data(existing, data, max_size) do
    combined = existing <> data
    combined_size = byte_size(combined)

    if combined_size <= max_size do
      combined
    else
      :binary.part(combined, combined_size - max_size, max_size)
    end
  end

  defp dispatch_stderr_callback(callback, lines)
       when is_function(callback, 1) and is_list(lines) do
    Enum.each(lines, callback)
  end

  defp dispatch_stderr_callback(_callback, _lines), do: :ok

  defp cleanup_pending_calls(pending_calls) do
    Enum.each(pending_calls, fn {ref, from} ->
      Process.demonitor(ref, [:flush])
      GenServer.reply(from, transport_error(Error.transport_stopped()))
    end)
  end

  defp demonitor_subscribers(subscribers) do
    Enum.each(subscribers, fn {_pid, %{monitor_ref: ref}} ->
      Process.demonitor(ref, [:flush])
    end)
  end

  defp force_stop_subprocess(%{subprocess: {pid, _os_pid}} = state) do
    stop_subprocess(pid)
    %{state | subprocess: nil, status: :disconnected}
  end

  defp force_stop_subprocess(state), do: state

  defp stop_subprocess(pid) when is_pid(pid) do
    :exec.stop(pid)
    _ = :exec.kill(pid, 9)
    :ok
  catch
    _, _ -> :ok
  end

  defp drop_until_next_newline(data) when is_binary(data) do
    case :binary.match(data, "\n") do
      :nomatch ->
        :none

      {idx, 1} ->
        rest_start = idx + 1
        rest_size = byte_size(data) - rest_start

        rest =
          if rest_size > 0 do
            :binary.part(data, rest_start, rest_size)
          else
            ""
          end

        {:rest, rest}
    end
  end

  defp preview(data) when is_binary(data) do
    max_preview = 160

    if byte_size(data) <= max_preview do
      data
    else
      :binary.part(data, 0, max_preview)
    end
  end

  defp normalize_payload(message) when is_binary(message), do: message
  defp normalize_payload(message) when is_map(message), do: Jason.encode!(message)

  defp normalize_payload(message) when is_list(message) do
    IO.iodata_to_binary(message)
  rescue
    ArgumentError ->
      Jason.encode!(message)
  end

  defp normalize_payload(message), do: to_string(message)

  defp ensure_newline(payload) do
    if String.ends_with?(payload, "\n"), do: payload, else: payload <> "\n"
  end

  defp transport_error({:transport, %Error{}} = error), do: {:error, error}
  defp transport_error(%Error{} = error), do: {:error, {:transport, error}}
  defp transport_error(reason), do: {:error, {:transport, Error.transport_error(reason)}}
end
