defmodule CliSubprocessCore.Channel do
  @moduledoc """
  Generic long-lived CLI IO channel above the raw session layer.

  Channels own the subprocess session lifecycle and expose mailbox delivery for
  framed stdout, stderr, exit, and transport-error events without tying callers
  to raw transport refs.
  """

  use GenServer

  import Kernel, except: [send: 2]

  alias CliSubprocessCore.{Channel.Delivery, Command, RawSession, TransportCompat}
  alias ExecutionPlane.Process.Transport
  alias ExternalRuntimeTransport.ProcessExit

  @default_channel_event_tag :cli_subprocess_core_channel
  @raw_session_event_tag :cli_subprocess_core_channel_transport
  @channel_start_timeout_ms 5_000

  @reserved_keys [:subscriber, :starter, :channel_event_tag]

  defstruct invocation: nil,
            raw_session: nil,
            channel_event_tag: @default_channel_event_tag,
            subscribers: %{}

  @type t :: pid()

  @type subscriber_info :: %{
          monitor_ref: reference(),
          tag: :legacy | reference()
        }

  @type extracted_event ::
          {:message, binary()}
          | {:data, binary()}
          | {:stderr, binary()}
          | {:exit, ProcessExit.t()}
          | {:error, term()}

  @type info_t :: %{
          delivery: Delivery.t(),
          invocation: Command.t(),
          subscribers: non_neg_integer(),
          raw_session: RawSession.info_t(),
          transport: term()
        }

  @doc """
  Starts an unlinked channel from normalized options.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts) when is_list(opts) do
    case normalize_invocation(opts) do
      {:ok, invocation, channel_opts} ->
        start_with_invocation(:start, invocation, channel_opts)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Starts an unlinked channel from an invocation.
  """
  @spec start(Command.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%Command{} = invocation, opts) when is_list(opts) do
    start_with_invocation(:start, invocation, opts)
  end

  @doc """
  Starts an unlinked channel from an executable plus argv.
  """
  @spec start(String.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def start(command, args, opts) when is_binary(command) and is_list(args) and is_list(opts) do
    invocation =
      Command.new(command, args,
        cwd: Keyword.get(opts, :cwd),
        env: Keyword.get(opts, :env, %{}),
        clear_env?: Keyword.get(opts, :clear_env?, false),
        user: Keyword.get(opts, :user)
      )

    start_with_invocation(:start, invocation, opts)
  end

  @doc """
  Starts a linked channel from normalized options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case normalize_invocation(opts) do
      {:ok, invocation, channel_opts} ->
        start_with_invocation(:start_link, invocation, channel_opts)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Starts a linked channel from an invocation.
  """
  @spec start_link(Command.t(), keyword()) :: GenServer.on_start()
  def start_link(%Command{} = invocation, opts) when is_list(opts) do
    start_with_invocation(:start_link, invocation, opts)
  end

  @doc """
  Starts a linked channel from an executable plus argv.
  """
  @spec start_link(String.t(), [String.t()], keyword()) :: GenServer.on_start()
  def start_link(command, args, opts)
      when is_binary(command) and is_list(args) and is_list(opts) do
    invocation =
      Command.new(command, args,
        cwd: Keyword.get(opts, :cwd),
        env: Keyword.get(opts, :env, %{}),
        clear_env?: Keyword.get(opts, :clear_env?, false),
        user: Keyword.get(opts, :user)
      )

    start_with_invocation(:start_link, invocation, opts)
  end

  @doc """
  Starts a linked channel and returns its initial info snapshot.
  """
  @spec start_link_channel(keyword()) :: {:ok, pid(), info_t()} | {:error, term()}
  def start_link_channel(opts) when is_list(opts) do
    with_trap_exit(fn -> start_with_info(:start_link, opts) end)
  end

  @doc """
  Starts an unlinked channel and returns its initial info snapshot.
  """
  @spec start_channel(keyword()) :: {:ok, pid(), info_t()} | {:error, term()}
  def start_channel(opts) when is_list(opts) do
    start_with_info(:start, opts)
  end

  @doc """
  Sends input bytes to the underlying session.
  """
  @spec send(pid(), iodata()) :: :ok | {:error, term()}
  def send(channel, input) when is_pid(channel) do
    GenServer.call(channel, {:send, input})
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Alias for `send/2`.
  """
  @spec send_input(pid(), iodata()) :: :ok | {:error, term()}
  def send_input(channel, input) when is_pid(channel), do: send(channel, input)

  @doc """
  Closes stdin for EOF-driven sessions.
  """
  @spec end_input(pid()) :: :ok | {:error, term()}
  def end_input(channel) when is_pid(channel) do
    GenServer.call(channel, :end_input)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Alias for `end_input/1`.
  """
  @spec close_input(pid()) :: :ok | {:error, term()}
  def close_input(channel) when is_pid(channel), do: end_input(channel)

  @doc """
  Interrupts the underlying session.
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(channel) when is_pid(channel) do
    GenServer.call(channel, :interrupt)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Stops the channel and closes the underlying raw session.
  """
  @spec close(pid()) :: :ok
  def close(channel) when is_pid(channel) do
    GenServer.stop(channel, :normal)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Alias for `close/1`.
  """
  @spec stop(pid()) :: :ok
  def stop(channel) when is_pid(channel), do: close(channel)

  @doc """
  Forces the channel down immediately.
  """
  @spec force_close(pid()) :: :ok | {:error, term()}
  def force_close(channel) when is_pid(channel) do
    GenServer.call(channel, :force_close)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Subscribes a process in legacy mode.
  """
  @spec subscribe(pid(), pid()) :: :ok | {:error, term()}
  def subscribe(channel, pid) when is_pid(channel) and is_pid(pid) do
    subscribe(channel, pid, :legacy)
  end

  @doc """
  Subscribes a process with an explicit tag.
  """
  @spec subscribe(pid(), pid(), :legacy | reference()) :: :ok | {:error, term()}
  def subscribe(channel, pid, tag)
      when is_pid(channel) and is_pid(pid) and (tag == :legacy or is_reference(tag)) do
    GenServer.call(channel, {:subscribe, pid, tag})
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Removes a subscriber.
  """
  @spec unsubscribe(pid(), pid()) :: :ok
  def unsubscribe(channel, pid) when is_pid(channel) and is_pid(pid) do
    GenServer.call(channel, {:unsubscribe, pid})
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns channel runtime information.
  """
  @spec info(pid()) :: info_t() | %{}
  def info(channel) when is_pid(channel) do
    GenServer.call(channel, :info)
  catch
    :exit, _reason -> %{}
  end

  @doc """
  Returns stable mailbox-delivery metadata for tagged subscribers.
  """
  @spec delivery_info(pid()) :: Delivery.t() | nil
  def delivery_info(channel) when is_pid(channel) do
    case info(channel) do
      %{delivery: %Delivery{} = delivery} -> delivery
      _other -> nil
    end
  end

  @doc """
  Returns the channel status.
  """
  @spec status(pid()) :: :connected | :disconnected | :error
  def status(channel) when is_pid(channel) do
    case info(channel) do
      %{transport: %{status: status}} when status in [:connected, :disconnected, :error] -> status
      _other -> :disconnected
    end
  end

  @doc """
  Returns the latest stderr tail retained by the transport.
  """
  @spec stderr(pid()) :: binary()
  def stderr(channel) when is_pid(channel) do
    case info(channel) do
      %{transport: %{stderr: stderr}} when is_binary(stderr) -> stderr
      _other -> ""
    end
  end

  @doc """
  Extracts a normalized channel event from a legacy mailbox message.
  """
  @spec extract_event(term()) :: {:ok, extracted_event()} | :error
  def extract_event({:channel_message, line}) when is_binary(line), do: {:ok, {:message, line}}
  def extract_event({:channel_data, chunk}) when is_binary(chunk), do: {:ok, {:data, chunk}}
  def extract_event({:channel_stderr, chunk}) when is_binary(chunk), do: {:ok, {:stderr, chunk}}
  def extract_event({:channel_exit, %ProcessExit{} = exit}), do: {:ok, {:exit, exit}}
  def extract_event({:channel_error, reason}), do: {:ok, {:error, reason}}
  def extract_event(_message), do: :error

  @doc """
  Extracts a normalized channel event for a tagged subscriber reference.
  """
  @spec extract_event(term(), reference()) :: {:ok, extracted_event()} | :error
  def extract_event({event_tag, ref, payload}, ref) when is_atom(event_tag) do
    case payload do
      {:message, line} when is_binary(line) -> {:ok, {:message, line}}
      {:data, chunk} when is_binary(chunk) -> {:ok, {:data, chunk}}
      {:stderr, chunk} when is_binary(chunk) -> {:ok, {:stderr, chunk}}
      {:exit, %ProcessExit{} = exit} -> {:ok, {:exit, exit}}
      {:error, reason} -> {:ok, {:error, reason}}
      _other -> :error
    end
  end

  def extract_event(message, _ref), do: extract_event(message)

  @impl GenServer
  def init({%Command{} = invocation, opts}) do
    subscriber = Keyword.get(opts, :subscriber)
    channel_event_tag = Keyword.get(opts, :channel_event_tag, @default_channel_event_tag)

    with :ok <- validate_subscriber(subscriber),
         :ok <- validate_channel_event_tag(channel_event_tag),
         {:ok, raw_session} <- start_raw_session(invocation, opts) do
      state =
        %__MODULE__{
          invocation: invocation,
          raw_session: raw_session,
          channel_event_tag: channel_event_tag,
          subscribers: %{}
        }
        |> maybe_put_subscriber(subscriber)

      maybe_send_started(state, Keyword.get(opts, :starter))

      {:ok, state}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:send, input}, _from, state) do
    {:reply, RawSession.send_input(state.raw_session, input), state}
  end

  def handle_call(:end_input, _from, state) do
    {:reply, RawSession.close_input(state.raw_session), state}
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, RawSession.interrupt(state.raw_session), state}
  end

  def handle_call(:force_close, _from, state) do
    {:reply, RawSession.force_close(state.raw_session), state}
  end

  def handle_call({:subscribe, pid, tag}, _from, state) do
    {:reply, :ok, put_subscriber(state, pid, tag)}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, remove_subscriber(state, pid)}
  end

  def handle_call(:info, _from, state) do
    {:reply, channel_info(state), state}
  end

  @impl GenServer
  def handle_info(message, %{raw_session: %RawSession{transport_ref: transport_ref}} = state) do
    case Transport.extract_event(message, transport_ref) do
      {:ok, {:message, line}} ->
        dispatch_event(state, {:message, line})
        {:noreply, state}

      {:ok, {:data, chunk}} ->
        dispatch_event(state, {:data, chunk})
        {:noreply, state}

      {:ok, {:stderr, chunk}} ->
        dispatch_event(state, {:stderr, chunk})
        {:noreply, state}

      {:ok, {:error, reason}} ->
        dispatch_event(state, {:error, TransportCompat.to_transport_error(reason)})
        {:stop, :normal, state}

      {:ok, {:exit, exit}} ->
        dispatch_event(state, {:exit, TransportCompat.to_process_exit(exit)})
        {:stop, :normal, state}

      :error ->
        handle_other_info(message, state)
    end
  end

  defp handle_other_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    {:noreply, remove_subscriber_by_monitor(state, monitor_ref, pid)}
  end

  defp handle_other_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    demonitor_subscribers(state.subscribers)
    _ = RawSession.stop(state.raw_session)
    :ok
  catch
    _, _ -> :ok
  end

  defp start_with_invocation(fun, %Command{} = invocation, opts)
       when fun in [:start, :start_link] and is_list(opts) do
    Application.ensure_all_started(:cli_subprocess_core)

    {genserver_opts, init_opts} = Keyword.split(opts, [:name])
    apply(GenServer, fun, [__MODULE__, {invocation, init_opts}, genserver_opts])
  end

  defp start_with_info(fun, opts) when fun in [:start, :start_link] and is_list(opts) do
    ref = make_ref()
    opts = Keyword.put(opts, :starter, {self(), ref})

    case apply(__MODULE__, fun, [opts]) do
      {:ok, pid} ->
        receive do
          {:cli_subprocess_core_channel_started, ^ref, info} ->
            {:ok, pid, info}

          {:EXIT, ^pid, reason} ->
            {:error, reason}
        after
          @channel_start_timeout_ms ->
            close(pid)
            {:error, :channel_start_timeout}
        end

      {:error, _reason} = error ->
        error
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

  defp normalize_invocation(opts) when is_list(opts) do
    case Keyword.get(opts, :command) do
      %Command{} = invocation ->
        {:ok, invocation, Keyword.delete(opts, :command)}

      command when is_binary(command) ->
        invocation =
          Command.new(command, Keyword.get(opts, :args, []),
            cwd: Keyword.get(opts, :cwd),
            env: Keyword.get(opts, :env, %{}),
            clear_env?: Keyword.get(opts, :clear_env?, false),
            user: Keyword.get(opts, :user)
          )

        {:ok, invocation, opts}

      nil ->
        {:error, :missing_command}

      other ->
        {:error, {:invalid_command, other}}
    end
  end

  defp start_raw_session(%Command{} = invocation, opts) do
    raw_session_opts =
      opts
      |> Keyword.drop(@reserved_keys)
      |> Keyword.put(:receiver, self())
      |> Keyword.put(:event_tag, @raw_session_event_tag)

    RawSession.start(invocation, raw_session_opts)
  end

  defp validate_subscriber(nil), do: :ok
  defp validate_subscriber(pid) when is_pid(pid), do: :ok

  defp validate_subscriber({pid, tag}) when is_pid(pid) and (tag == :legacy or is_reference(tag)),
    do: :ok

  defp validate_subscriber(subscriber), do: {:error, {:invalid_subscriber, subscriber}}

  defp validate_channel_event_tag(tag) when is_atom(tag), do: :ok
  defp validate_channel_event_tag(tag), do: {:error, {:invalid_channel_event_tag, tag}}

  defp maybe_send_started(_state, nil), do: :ok

  defp maybe_send_started(state, {pid, ref}) when is_pid(pid) and is_reference(ref) do
    Kernel.send(pid, {:cli_subprocess_core_channel_started, ref, channel_info(state)})
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

  defp demonitor_subscribers(subscribers) do
    Enum.each(subscribers, fn {_pid, %{monitor_ref: monitor_ref}} ->
      Process.demonitor(monitor_ref, [:flush])
    end)
  end

  defp dispatch_event(state, {:message, line}) do
    Enum.each(state.subscribers, fn
      {pid, %{tag: :legacy}} ->
        Kernel.send(pid, {:channel_message, line})

      {pid, %{tag: tag}} when is_reference(tag) ->
        Kernel.send(pid, {state.channel_event_tag, tag, {:message, line}})

      _other ->
        :ok
    end)
  end

  defp dispatch_event(state, {:data, chunk}) do
    Enum.each(state.subscribers, fn
      {pid, %{tag: :legacy}} ->
        Kernel.send(pid, {:channel_data, chunk})

      {pid, %{tag: tag}} when is_reference(tag) ->
        Kernel.send(pid, {state.channel_event_tag, tag, {:data, chunk}})

      _other ->
        :ok
    end)
  end

  defp dispatch_event(state, {:stderr, chunk}) do
    Enum.each(state.subscribers, fn
      {pid, %{tag: :legacy}} ->
        Kernel.send(pid, {:channel_stderr, chunk})

      {pid, %{tag: tag}} when is_reference(tag) ->
        Kernel.send(pid, {state.channel_event_tag, tag, {:stderr, chunk}})

      _other ->
        :ok
    end)
  end

  defp dispatch_event(state, {:exit, %ProcessExit{} = exit}) do
    Enum.each(state.subscribers, fn
      {pid, %{tag: :legacy}} ->
        Kernel.send(pid, {:channel_exit, exit})

      {pid, %{tag: tag}} when is_reference(tag) ->
        Kernel.send(pid, {state.channel_event_tag, tag, {:exit, exit}})

      _other ->
        :ok
    end)
  end

  defp dispatch_event(state, {:error, reason}) do
    Enum.each(state.subscribers, fn
      {pid, %{tag: :legacy}} ->
        Kernel.send(pid, {:channel_error, reason})

      {pid, %{tag: tag}} when is_reference(tag) ->
        Kernel.send(pid, {state.channel_event_tag, tag, {:error, reason}})

      _other ->
        :ok
    end)
  end

  defp channel_info(state) do
    raw_session_info = RawSession.info(state.raw_session)

    %{
      delivery: Delivery.new(state.channel_event_tag),
      invocation: state.invocation,
      subscribers: map_size(state.subscribers),
      raw_session: raw_session_info,
      transport: raw_session_info.transport
    }
  end
end
