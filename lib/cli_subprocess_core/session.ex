defmodule CliSubprocessCore.Session do
  @moduledoc """
  Common CLI session runtime above the raw transport layer.
  """

  use GenServer

  import Kernel, except: [send: 2]

  alias CliSubprocessCore.{
    Event,
    Payload,
    ProviderProfile,
    ProviderRegistry,
    Runtime,
    Session.Delivery,
    Session.Options,
    Transport.Info
  }

  @session_start_timeout_ms 5_000
  @transport_event_tag :cli_subprocess_core_session_transport
  @transport_start_timeout_ms 5_000
  @transport_start_poll_ms 10

  defstruct provider: nil,
            profile: nil,
            invocation: nil,
            options: nil,
            runtime: nil,
            parser_state: nil,
            subscribers: %{},
            transport_pid: nil,
            transport_ref: nil

  @type subscriber_info :: %{
          monitor_ref: reference(),
          tag: :legacy | reference()
        }

  @type t :: %__MODULE__{
          provider: atom(),
          profile: module(),
          invocation: CliSubprocessCore.Command.t(),
          options: Options.t(),
          runtime: Runtime.t(),
          parser_state: term(),
          subscribers: %{optional(pid()) => subscriber_info()},
          transport_pid: pid(),
          transport_ref: reference()
        }

  @doc """
  Starts a linked session process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    Application.ensure_all_started(:cli_subprocess_core)

    {genserver_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, genserver_opts)
  end

  @doc """
  Starts a linked session and returns the pid together with its initial info
  snapshot.
  """
  @spec start_link_session(keyword()) :: {:ok, pid(), map()} | {:error, term()}
  def start_link_session(opts) when is_list(opts) do
    with_trap_exit(fn -> start_with_info(:start_link, opts) end)
  end

  @doc """
  Starts a session and returns the pid together with its initial info snapshot.
  """
  @spec start_session(keyword()) :: {:ok, pid(), map()} | {:error, term()}
  def start_session(opts) when is_list(opts) do
    start_with_info(:start, opts)
  end

  @doc """
  Sends provider input through the underlying transport.
  """
  @spec send(pid(), iodata() | map() | list()) :: :ok | {:error, term()}
  def send(session, input) when is_pid(session) do
    GenServer.call(session, {:send, input})
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Alias for `send/2` that preserves the runtime-kit naming.
  """
  @spec send_input(pid(), iodata() | map() | list(), keyword()) :: :ok | {:error, term()}
  def send_input(session, input, _opts \\ []) when is_pid(session) do
    send(session, input)
  end

  @doc """
  Closes stdin for EOF-driven CLIs.
  """
  @spec end_input(pid()) :: :ok | {:error, term()}
  def end_input(session) when is_pid(session) do
    GenServer.call(session, :end_input)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Sends an interrupt request to the underlying transport.
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) when is_pid(session) do
    GenServer.call(session, :interrupt)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Stops the session and closes the transport.
  """
  @spec close(pid()) :: :ok
  def close(session) when is_pid(session) do
    GenServer.stop(session, :normal)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Subscribes a process in legacy mode.
  """
  @spec subscribe(pid(), pid()) :: :ok | {:error, term()}
  def subscribe(session, pid) when is_pid(session) and is_pid(pid) do
    subscribe(session, pid, :legacy)
  end

  @doc """
  Subscribes a process with an explicit tag.
  """
  @spec subscribe(pid(), pid(), :legacy | reference()) :: :ok | {:error, term()}
  def subscribe(session, pid, tag)
      when is_pid(session) and is_pid(pid) and (tag == :legacy or is_reference(tag)) do
    GenServer.call(session, {:subscribe, pid, tag})
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Removes a subscriber.
  """
  @spec unsubscribe(pid(), pid()) :: :ok
  def unsubscribe(session, pid) when is_pid(session) and is_pid(pid) do
    GenServer.call(session, {:unsubscribe, pid})
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns session runtime and transport information.
  """
  @spec info(pid()) :: map()
  def info(session) when is_pid(session) do
    GenServer.call(session, :info)
  catch
    :exit, _reason -> %{}
  end

  @doc """
  Extracts a normalized session event from a legacy mailbox message.

  Tagged subscribers should use `extract_event/2` so their code does not
  depend on a specific outer event atom.
  """
  @spec extract_event(term()) :: {:ok, Event.t()} | :error
  def extract_event({:session_event, %Event{} = event}), do: {:ok, event}
  def extract_event(_message), do: :error

  @doc """
  Extracts a normalized session event for a tagged subscriber reference.

  This is the stable core-owned way for adapters to consume session delivery
  without hard-coding the configured outer event atom.
  """
  @spec extract_event(term(), reference()) :: {:ok, Event.t()} | :error
  def extract_event({event_tag, ref, {:event, %Event{} = event}}, ref) when is_atom(event_tag) do
    {:ok, event}
  end

  def extract_event(message, _ref), do: extract_event(message)

  @doc """
  Returns stable mailbox-delivery metadata for the current session.
  """
  @spec delivery_info(pid()) :: Delivery.t() | nil
  def delivery_info(session) when is_pid(session) do
    case info(session) do
      %{delivery: %Delivery{} = delivery} -> delivery
      _other -> nil
    end
  end

  @impl GenServer
  def init(opts) do
    with {:ok, options} <- Options.new(opts),
         {:ok, profile} <- resolve_profile(options),
         {:ok, invocation} <- profile.build_invocation(options.provider_options),
         :ok <- ProviderProfile.validate_invocation(invocation),
         {:ok, transport_pid, transport_ref} <- start_transport(options, profile, invocation) do
      state =
        %__MODULE__{
          provider: options.provider,
          profile: profile,
          invocation: invocation,
          options: options,
          runtime:
            Runtime.new(provider: options.provider, profile: profile, metadata: options.metadata),
          parser_state: profile.init_parser_state(options.provider_options),
          subscribers: %{},
          transport_pid: transport_pid,
          transport_ref: transport_ref
        }
        |> maybe_put_subscriber(options.subscriber)

      maybe_send_started(state)

      {:ok, state, {:continue, :emit_run_started}}
    else
      :error ->
        {:stop, {:provider_not_found, Keyword.get(opts, :provider)}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:emit_run_started, state) do
    payload =
      Payload.RunStarted.new(
        provider_session_id: state.runtime.provider_session_id,
        command: state.invocation.command,
        args: state.invocation.args,
        cwd: state.invocation.cwd
      )

    {event, runtime} = Runtime.next_event(state.runtime, :run_started, payload)
    dispatch_event(state, event)

    {:noreply, %{state | runtime: runtime}}
  end

  @impl GenServer
  def handle_call({:send, input}, _from, state) do
    {:reply, CliSubprocessCore.Transport.send(state.transport_pid, input), state}
  end

  def handle_call(:end_input, _from, state) do
    {:reply, CliSubprocessCore.Transport.end_input(state.transport_pid), state}
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, CliSubprocessCore.Transport.interrupt(state.transport_pid), state}
  end

  def handle_call({:subscribe, pid, tag}, _from, state) do
    {:reply, :ok, put_subscriber(state, pid, tag)}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, remove_subscriber(state, pid)}
  end

  def handle_call(:info, _from, state) do
    {:reply, session_info(state), state}
  end

  @impl GenServer
  def handle_info({@transport_event_tag, ref, {:message, line}}, %{transport_ref: ref} = state) do
    {events, parser_state} = state.profile.decode_stdout(line, state.parser_state)
    state = %{state | parser_state: parser_state}
    {:noreply, normalize_and_dispatch(state, events)}
  end

  def handle_info({@transport_event_tag, ref, {:stderr, chunk}}, %{transport_ref: ref} = state) do
    {events, parser_state} = state.profile.decode_stderr(chunk, state.parser_state)
    state = %{state | parser_state: parser_state}
    {:noreply, normalize_and_dispatch(state, events)}
  end

  def handle_info(
        {@transport_event_tag, ref, {:error, transport_error}},
        %{transport_ref: ref} = state
      ) do
    payload =
      Payload.Error.new(
        message: transport_error.message,
        code: "transport_error",
        metadata: transport_error.context
      )

    {event, runtime} = Runtime.next_event(state.runtime, :error, payload, raw: transport_error)
    dispatch_event(state, event)

    {:noreply, %{state | runtime: runtime}}
  end

  def handle_info(
        {@transport_event_tag, ref, {:exit, process_exit}},
        %{transport_ref: ref} = state
      ) do
    {events, parser_state} = state.profile.handle_exit(process_exit.reason, state.parser_state)
    state = %{state | parser_state: parser_state}
    state = normalize_and_dispatch(state, events)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    {:noreply, remove_subscriber_by_monitor(state, monitor_ref, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if is_pid(state.transport_pid) do
      _ = CliSubprocessCore.Transport.close(state.transport_pid)
    end

    :ok
  end

  defp resolve_profile(%Options{profile: profile}) when is_atom(profile) and not is_nil(profile),
    do: {:ok, profile}

  defp resolve_profile(%Options{provider: provider, registry: registry}) do
    ProviderRegistry.fetch(provider, registry)
  catch
    :exit, reason -> {:error, reason}
  end

  defp start_with_info(start_fun, opts) when start_fun in [:start, :start_link] do
    Application.ensure_all_started(:cli_subprocess_core)

    ref = make_ref()

    {genserver_opts, init_opts} =
      Keyword.split(Keyword.put(opts, :starter, {self(), ref}), [:name])

    case apply(GenServer, start_fun, [__MODULE__, init_opts, genserver_opts]) do
      {:ok, pid} ->
        await_started_session(pid, ref)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_started_session(pid, ref, timeout_ms \\ @session_start_timeout_ms) do
    receive do
      {:cli_subprocess_core_session_started, ^ref, info} ->
        {:ok, pid, info}

      {:EXIT, ^pid, reason} ->
        {:error, reason}
    after
      timeout_ms ->
        safe_stop_started_session(pid)
        {:error, :session_start_timeout}
    end
  end

  defp with_trap_exit(fun) when is_function(fun, 0) do
    previous_trap_exit? = Process.flag(:trap_exit, true)

    try do
      fun.()
    after
      Process.flag(:trap_exit, previous_trap_exit?)
    end
  end

  defp start_transport(options, profile, invocation) do
    transport_ref = make_ref()

    transport_options =
      options.provider_options
      |> profile.transport_options()
      |> Keyword.drop([:command, :args, :cwd, :env, :subscriber, :event_tag])
      |> Keyword.merge(options.transport_options)

    transport_opts =
      [
        command: invocation,
        subscriber: {self(), transport_ref},
        event_tag: @transport_event_tag,
        surface_kind: options.surface_kind,
        transport_options: transport_options,
        target_id: options.target_id,
        lease_ref: options.lease_ref,
        surface_ref: options.surface_ref,
        boundary_class: options.boundary_class,
        observability: options.observability
      ]

    case CliSubprocessCore.Transport.start(transport_opts) do
      {:ok, transport_pid} ->
        case await_transport_started(CliSubprocessCore.Transport, transport_pid) do
          :ok ->
            {:ok, transport_pid, transport_ref}

          {:error, reason} ->
            safe_close_transport(CliSubprocessCore.Transport, transport_pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_and_dispatch(state, events) do
    Enum.reduce(events, state, fn event, acc ->
      runtime =
        case event.provider_session_id do
          value when is_binary(value) -> Runtime.put_provider_session_id(acc.runtime, value)
          _ -> acc.runtime
        end

      {normalized, runtime} =
        Runtime.next_event(
          runtime,
          event.kind,
          event.payload,
          raw: event.raw,
          provider_session_id: event.provider_session_id,
          metadata: event.metadata
        )

      dispatch_event(%{acc | runtime: runtime}, normalized)
      %{acc | runtime: runtime}
    end)
  end

  defp session_info(state) do
    transport_info = maybe_transport_info(CliSubprocessCore.Transport, state.transport_pid)

    transport_status =
      transport_status(CliSubprocessCore.Transport, state.transport_pid, transport_info)

    transport_stderr =
      transport_stderr(CliSubprocessCore.Transport, state.transport_pid, transport_info)

    %{
      capabilities: state.profile.capabilities(),
      delivery: Delivery.new(state.options.session_event_tag),
      invocation: state.invocation,
      metadata: state.options.metadata,
      profile: state.profile,
      provider: state.provider,
      runtime: Runtime.info(state.runtime),
      session_event_tag: state.options.session_event_tag,
      subscribers: map_size(state.subscribers),
      transport:
        build_transport_snapshot(
          CliSubprocessCore.Transport,
          state.transport_pid,
          transport_status,
          transport_stderr,
          transport_info
        )
    }
  end

  defp maybe_send_started(%{options: %Options{starter: nil}}), do: :ok

  defp maybe_send_started(%{options: %Options{starter: {pid, ref}}} = state) do
    Kernel.send(pid, {:cli_subprocess_core_session_started, ref, session_info(state)})
    :ok
  end

  defp maybe_put_subscriber(state, nil), do: state
  defp maybe_put_subscriber(state, pid) when is_pid(pid), do: put_subscriber(state, pid, :legacy)

  defp maybe_put_subscriber(state, {pid, tag}) when is_pid(pid) do
    put_subscriber(state, pid, tag)
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
  end

  defp remove_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {%{monitor_ref: monitor_ref}, subscribers} ->
        Process.demonitor(monitor_ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  defp remove_subscriber_by_monitor(state, monitor_ref, pid) do
    case Map.get(state.subscribers, pid) do
      %{monitor_ref: ^monitor_ref} -> %{state | subscribers: Map.delete(state.subscribers, pid)}
      _other -> state
    end
  end

  defp dispatch_event(state, %Event{} = event) do
    Enum.each(state.subscribers, fn
      {pid, %{tag: :legacy}} ->
        Kernel.send(pid, {:session_event, event})

      {pid, %{tag: tag}} when is_reference(tag) ->
        Kernel.send(pid, {state.options.session_event_tag, tag, {:event, event}})

      _other ->
        :ok
    end)
  end

  defp await_transport_started(module, transport, timeout_ms \\ @transport_start_timeout_ms)
       when is_atom(module) and is_pid(transport) and is_integer(timeout_ms) and timeout_ms > 0 do
    monitor_ref = Process.monitor(transport)
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    try do
      do_await_transport_started(module, transport, monitor_ref, deadline_ms)
    after
      Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp do_await_transport_started(module, transport, monitor_ref, deadline_ms) do
    case module.status(transport) do
      :connected ->
        :ok

      _status ->
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:error, :transport_start_timeout}
        else
          receive do
            {:DOWN, ^monitor_ref, :process, ^transport, reason} ->
              normalize_transport_start_exit(reason)
          after
            min(@transport_start_poll_ms, remaining_ms) ->
              do_await_transport_started(module, transport, monitor_ref, deadline_ms)
          end
        end
    end
  end

  defp normalize_transport_start_exit({:transport, %CliSubprocessCore.Transport.Error{} = error}),
    do: {:error, {:transport, error}}

  defp normalize_transport_start_exit(%CliSubprocessCore.Transport.Error{} = error),
    do: {:error, {:transport, error}}

  defp normalize_transport_start_exit({:shutdown, %CliSubprocessCore.Transport.Error{} = error}),
    do: {:error, {:transport, error}}

  defp normalize_transport_start_exit(:normal), do: :ok
  defp normalize_transport_start_exit(reason), do: {:error, reason}

  defp maybe_transport_info(module, transport_pid) do
    if function_exported?(module, :info, 1) do
      case module.info(transport_pid) do
        %Info{} = info -> info
        _other -> nil
      end
    else
      nil
    end
  end

  defp transport_status(_module, _transport_pid, %Info{} = info), do: info.status
  defp transport_status(module, transport_pid, nil), do: module.status(transport_pid)

  defp transport_stderr(_module, _transport_pid, %Info{} = info), do: info.stderr
  defp transport_stderr(module, transport_pid, nil), do: module.stderr(transport_pid)

  defp build_transport_snapshot(module, transport_pid, status, stderr, nil) do
    %{
      delivery: nil,
      module: module,
      pid: transport_pid,
      status: status,
      stderr: stderr
    }
  end

  defp build_transport_snapshot(module, transport_pid, status, stderr, %Info{} = info) do
    %{
      delivery: info.delivery,
      module: module,
      pid: transport_pid,
      status: status,
      stderr: stderr,
      info: info,
      subprocess_pid: info.pid,
      os_pid: info.os_pid,
      stdout_mode: info.stdout_mode,
      stdin_mode: info.stdin_mode,
      pty?: info.pty?,
      interrupt_mode: info.interrupt_mode
    }
  end

  defp safe_close_transport(module, transport) do
    module.close(transport)
  catch
    :exit, _reason -> :ok
  end

  defp safe_stop_started_session(pid) when is_pid(pid) do
    Process.exit(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
