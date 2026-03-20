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
    Session.Options
  }

  @transport_event_tag :cli_subprocess_core_session_transport

  defstruct provider: nil,
            profile: nil,
            invocation: nil,
            options: nil,
            runtime: nil,
            parser_state: nil,
            subscribers: %{},
            transport_module: nil,
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
          transport_module: module(),
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
  Starts a session and returns the pid together with its initial info snapshot.
  """
  @spec start_session(keyword()) :: {:ok, pid(), map()} | {:error, term()}
  def start_session(opts) when is_list(opts) do
    ref = make_ref()

    case start_link(Keyword.put(opts, :starter, {self(), ref})) do
      {:ok, pid} ->
        receive do
          {:cli_subprocess_core_session_started, ^ref, info} -> {:ok, pid, info}
        after
          5_000 ->
            {:error, :session_start_timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
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
          transport_module: options.transport_module,
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
    {:reply, state.transport_module.send(state.transport_pid, input), state}
  end

  def handle_call(:end_input, _from, state) do
    {:reply, state.transport_module.end_input(state.transport_pid), state}
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, state.transport_module.interrupt(state.transport_pid), state}
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
      _ = state.transport_module.close(state.transport_pid)
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

  defp start_transport(options, profile, invocation) do
    transport_ref = make_ref()

    transport_opts =
      options.provider_options
      |> profile.transport_options()
      |> Keyword.drop([:command, :args, :cwd, :env, :subscriber, :event_tag])
      |> Keyword.merge(command: invocation)
      |> Keyword.put(:subscriber, {self(), transport_ref})
      |> Keyword.put(:event_tag, @transport_event_tag)

    case options.transport_module.start(transport_opts) do
      {:ok, transport_pid} -> {:ok, transport_pid, transport_ref}
      {:error, reason} -> {:error, reason}
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
    %{
      capabilities: state.profile.capabilities(),
      invocation: state.invocation,
      metadata: state.options.metadata,
      profile: state.profile,
      provider: state.provider,
      runtime: Runtime.info(state.runtime),
      session_event_tag: state.options.session_event_tag,
      subscribers: map_size(state.subscribers),
      transport: %{
        module: state.transport_module,
        pid: state.transport_pid,
        status: state.transport_module.status(state.transport_pid),
        stderr: state.transport_module.stderr(state.transport_pid)
      }
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
end
