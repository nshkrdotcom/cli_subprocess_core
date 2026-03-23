defmodule CliSubprocessCore.RawSession do
  @moduledoc """
  Provider-agnostic handle for long-lived raw subprocess sessions.

  `CliSubprocessCore.Transport` owns the subprocess lifecycle itself. This
  module provides a higher-level contract for consumers that need a stable raw
  session handle, exact-byte stdin/stdout defaults, optional PTY startup, and
  normalized result collection without re-implementing lifecycle rules in
  provider repos.
  """

  alias CliSubprocessCore.{Command, ProcessExit, Transport}
  alias CliSubprocessCore.RawSession.Delivery
  alias CliSubprocessCore.Transport.Delivery, as: TransportDelivery
  alias CliSubprocessCore.Transport.{Info, RunResult}

  @default_event_tag :cli_subprocess_core_raw_session
  @transport_start_timeout_ms 5_000
  @transport_start_poll_ms 10
  @reserved_keys [
    :receiver,
    :event_tag,
    :transport_module,
    :stdin?,
    :stdout_mode,
    :stdin_mode,
    :pty?,
    :interrupt_mode
  ]

  @enforce_keys [
    :invocation,
    :receiver,
    :transport,
    :transport_ref,
    :event_tag,
    :transport_module,
    :stdout_mode,
    :stdin_mode,
    :interrupt_mode,
    :pty?,
    :stdin?
  ]
  defstruct [
    :invocation,
    :receiver,
    :transport,
    :transport_ref,
    :event_tag,
    :transport_module,
    :stdout_mode,
    :stdin_mode,
    :interrupt_mode,
    :pty?,
    :stdin?
  ]

  @type t :: %__MODULE__{
          invocation: Command.t(),
          receiver: pid(),
          transport: pid(),
          transport_ref: reference(),
          event_tag: atom(),
          transport_module: module(),
          stdout_mode: :line | :raw,
          stdin_mode: :line | :raw,
          interrupt_mode: :signal | {:stdin, binary()},
          pty?: boolean(),
          stdin?: boolean()
        }

  @type info_t :: %{
          delivery: Delivery.t(),
          invocation: Command.t(),
          receiver: pid(),
          transport_ref: reference(),
          event_tag: atom(),
          stdout_mode: :line | :raw,
          stdin_mode: :line | :raw,
          interrupt_mode: :signal | {:stdin, binary()},
          pty?: boolean(),
          stdin?: boolean(),
          transport: term()
        }

  @doc """
  Starts an unlinked raw subprocess session from either an executable and argv
  list or a prebuilt invocation plus options.
  """
  @spec start(String.t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  @spec start(Command.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(arg1, arg2)

  def start(command, args) when is_binary(command) and is_list(args) do
    start(command, args, [])
  end

  def start(%Command{} = invocation, opts) when is_list(opts) do
    do_start(:start, invocation, opts)
  end

  @spec start(String.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def start(command, args, opts) when is_binary(command) and is_list(args) and is_list(opts) do
    invocation =
      Command.new(command, args,
        cwd: Keyword.get(opts, :cwd),
        env: Keyword.get(opts, :env, %{}),
        clear_env?: Keyword.get(opts, :clear_env?, false),
        user: Keyword.get(opts, :user)
      )

    do_start(:start, invocation, opts)
  end

  @doc """
  Starts an unlinked raw subprocess session from a prebuilt invocation.
  """
  @spec start(Command.t()) :: {:ok, t()} | {:error, term()}
  def start(%Command{} = invocation) do
    start(invocation, [])
  end

  @doc """
  Starts a linked raw subprocess session from either an executable and argv
  list or a prebuilt invocation plus options.
  """
  @spec start_link(String.t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  @spec start_link(Command.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start_link(arg1, arg2)

  def start_link(command, args) when is_binary(command) and is_list(args) do
    start_link(command, args, [])
  end

  def start_link(%Command{} = invocation, opts) when is_list(opts) do
    do_start(:start_link, invocation, opts)
  end

  @spec start_link(String.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def start_link(command, args, opts)
      when is_binary(command) and is_list(args) and is_list(opts) do
    invocation =
      Command.new(command, args,
        cwd: Keyword.get(opts, :cwd),
        env: Keyword.get(opts, :env, %{}),
        clear_env?: Keyword.get(opts, :clear_env?, false),
        user: Keyword.get(opts, :user)
      )

    do_start(:start_link, invocation, opts)
  end

  @doc """
  Starts a linked raw subprocess session from a prebuilt invocation.
  """
  @spec start_link(Command.t()) :: {:ok, t()} | {:error, term()}
  def start_link(%Command{} = invocation) do
    start_link(invocation, [])
  end

  @doc """
  Sends exact input bytes through the session transport.
  """
  @spec send_input(t(), iodata()) :: :ok | {:error, term()}
  def send_input(%__MODULE__{stdin?: false}, _data), do: {:error, :stdin_unavailable}

  def send_input(%__MODULE__{transport_module: module, transport: transport}, data) do
    module.send(transport, data)
  end

  @doc """
  Closes stdin for EOF-driven subprocesses.
  """
  @spec close_input(t()) :: :ok | {:error, term()}
  def close_input(%__MODULE__{stdin?: false}), do: {:error, :stdin_unavailable}

  def close_input(%__MODULE__{transport_module: module, transport: transport}) do
    module.end_input(transport)
  end

  @doc """
  Stops the subprocess transport.
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{transport_module: module, transport: transport}) do
    module.close(transport)
  end

  @doc """
  Forces the subprocess down immediately.
  """
  @spec force_close(t()) :: :ok | {:error, term()}
  def force_close(%__MODULE__{transport_module: module, transport: transport}) do
    module.force_close(transport)
  end

  @doc """
  Interrupts the subprocess according to the configured transport contract.
  """
  @spec interrupt(t()) :: :ok | {:error, term()}
  def interrupt(%__MODULE__{transport_module: module, transport: transport}) do
    module.interrupt(transport)
  end

  @doc """
  Returns the transport status for the raw session.
  """
  @spec status(t()) :: :connected | :disconnected | :error
  def status(%__MODULE__{transport_module: module, transport: transport}) do
    module.status(transport)
  end

  @doc """
  Returns the stderr tail retained by the underlying transport.
  """
  @spec stderr(t()) :: binary()
  def stderr(%__MODULE__{transport_module: module, transport: transport}) do
    module.stderr(transport)
  end

  @doc """
  Returns the latest raw session metadata snapshot.
  """
  @spec info(t()) :: info_t()
  def info(%__MODULE__{} = session) do
    transport_info = session.transport_module.info(session.transport)

    %{
      delivery: delivery_info(session),
      invocation: session.invocation,
      receiver: session.receiver,
      transport_ref: session.transport_ref,
      event_tag: session.event_tag,
      stdout_mode: session.stdout_mode,
      stdin_mode: session.stdin_mode,
      interrupt_mode: session.interrupt_mode,
      pty?: session.pty?,
      stdin?: session.stdin?,
      transport: transport_info
    }
  end

  @doc """
  Returns stable mailbox-delivery metadata for the raw session.
  """
  @spec delivery_info(t()) :: Delivery.t()
  def delivery_info(%__MODULE__{} = session) do
    Delivery.new(session.receiver, session.transport_ref, session.event_tag)
  end

  @doc """
  Collects session output until the subprocess exits.

  The configured receiver must be the calling process so the core can consume
  its own transport events deterministically.
  """
  @spec collect(t(), timeout()) :: {:ok, RunResult.t()} | {:error, term()}
  def collect(%__MODULE__{receiver: receiver} = session, timeout_ms \\ 30_000) do
    cond do
      receiver != self() ->
        {:error, :receiver_mismatch}

      timeout_ms == :infinity ->
        do_collect(session, :infinity, [], [])

      is_integer(timeout_ms) and timeout_ms >= 0 ->
        do_collect(session, System.monotonic_time(:millisecond) + timeout_ms, [], [])

      true ->
        {:error, {:invalid_timeout, timeout_ms}}
    end
  end

  defp do_start(fun, %Command{} = invocation, opts) when fun in [:start, :start_link] do
    receiver = Keyword.get(opts, :receiver, self())
    event_tag = Keyword.get(opts, :event_tag, @default_event_tag)
    transport_module = Keyword.get(opts, :transport_module, Transport)
    stdin? = Keyword.get(opts, :stdin?, true)
    pty? = Keyword.get(opts, :pty?, false)
    stdout_mode = Keyword.get(opts, :stdout_mode, :raw)
    stdin_mode = Keyword.get(opts, :stdin_mode, :raw)
    interrupt_mode = Keyword.get(opts, :interrupt_mode, default_interrupt_mode(pty?))
    transport_ref = make_ref()

    with {:ok, _started_apps} <- Application.ensure_all_started(:cli_subprocess_core),
         :ok <- validate_receiver(receiver),
         :ok <- validate_event_tag(event_tag),
         :ok <- validate_transport_module(transport_module),
         :ok <- validate_stdin_available(stdin?) do
      transport_opts =
        opts
        |> Keyword.drop(@reserved_keys)
        |> Keyword.put(:command, invocation)
        |> Keyword.put(:subscriber, {receiver, transport_ref})
        |> Keyword.put(:event_tag, event_tag)
        |> Keyword.put_new(:stdout_mode, stdout_mode)
        |> Keyword.put_new(:stdin_mode, stdin_mode)
        |> Keyword.put_new(:pty?, pty?)
        |> Keyword.put_new(:interrupt_mode, interrupt_mode)

      case apply(transport_module, fun, [transport_opts]) do
        {:ok, transport} ->
          session_config = %{
            event_tag: event_tag,
            interrupt_mode: interrupt_mode,
            invocation: invocation,
            pty?: pty?,
            receiver: receiver,
            stdin?: stdin?,
            stdin_mode: stdin_mode,
            stdout_mode: stdout_mode,
            transport_module: transport_module,
            transport_ref: transport_ref
          }

          start_transport_session(session_config, transport)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp start_transport_session(%{transport_module: transport_module} = session_config, transport) do
    case await_transport_started(transport_module, transport) do
      :ok ->
        build_session(session_config, transport)

      {:error, reason} ->
        safe_close_transport(transport_module, transport)
        {:error, reason}
    end
  end

  defp build_session(
         %{
           event_tag: event_tag,
           interrupt_mode: interrupt_mode,
           invocation: invocation,
           pty?: pty?,
           receiver: receiver,
           stdin?: stdin?,
           stdin_mode: stdin_mode,
           stdout_mode: stdout_mode,
           transport_module: transport_module,
           transport_ref: transport_ref
         },
         transport
       ) do
    case transport_module.info(transport) do
      %Info{} = transport_info ->
        {:ok,
         %__MODULE__{
           invocation: invocation,
           receiver: receiver,
           transport: transport,
           transport_ref: transport_ref,
           event_tag: resolve_delivery_event_tag(transport_info, event_tag),
           transport_module: transport_module,
           stdout_mode: resolve_transport_contract(transport_info, :stdout_mode, stdout_mode),
           stdin_mode: resolve_transport_contract(transport_info, :stdin_mode, stdin_mode),
           interrupt_mode:
             resolve_transport_contract(transport_info, :interrupt_mode, interrupt_mode),
           pty?: resolve_transport_contract(transport_info, :pty?, pty?),
           stdin?: stdin?
         }}

      other ->
        transport_module.close(transport)
        {:error, {:invalid_transport_info, other}}
    end
  end

  defp do_collect(session, timeout, stdout, stderr) do
    receive do
      message ->
        case Transport.extract_event(message, session.transport_ref) do
          {:ok, {:data, chunk}} ->
            do_collect(session, timeout, [chunk | stdout], stderr)

          {:ok, {:message, line}} ->
            do_collect(session, timeout, [line | stdout], stderr)

          {:ok, {:stderr, chunk}} ->
            do_collect(session, timeout, stdout, [chunk | stderr])

          {:ok, {:error, reason}} ->
            {:error, {:transport, reason}}

          {:ok, {:exit, %ProcessExit{} = exit}} ->
            stdout = stdout |> Enum.reverse() |> IO.iodata_to_binary()
            stderr = stderr |> Enum.reverse() |> IO.iodata_to_binary()

            {:ok,
             %RunResult{
               invocation: session.invocation,
               output: stdout,
               stdout: stdout,
               stderr: stderr,
               exit: exit,
               stderr_mode: :separate
             }}

          :error ->
            do_collect(session, timeout, stdout, stderr)
        end
    after
      timeout_after(timeout) ->
        {:error, {:timeout, session}}
    end
  end

  defp timeout_after(:infinity), do: :infinity

  defp timeout_after(deadline_ms) when is_integer(deadline_ms) do
    remaining = deadline_ms - System.monotonic_time(:millisecond)
    if remaining > 0, do: remaining, else: 0
  end

  defp default_interrupt_mode(true), do: {:stdin, <<3>>}
  defp default_interrupt_mode(_pty?), do: :signal

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

  defp resolve_transport_contract(%Info{status: :connected} = transport_info, key, _fallback),
    do: Map.fetch!(transport_info, key)

  defp resolve_transport_contract(%Info{}, _key, fallback), do: fallback

  defp resolve_delivery_event_tag(
         %Info{delivery: %TransportDelivery{tagged_event_tag: tagged_event_tag}},
         _fallback
       )
       when is_atom(tagged_event_tag),
       do: tagged_event_tag

  defp resolve_delivery_event_tag(%Info{}, fallback), do: fallback

  defp safe_close_transport(module, transport) do
    module.close(transport)
  catch
    :exit, _reason -> :ok
  end

  defp validate_receiver(pid) when is_pid(pid), do: :ok
  defp validate_receiver(receiver), do: {:error, {:invalid_receiver, receiver}}

  defp validate_event_tag(tag) when is_atom(tag), do: :ok
  defp validate_event_tag(tag), do: {:error, {:invalid_event_tag, tag}}

  defp validate_stdin_available(value) when is_boolean(value), do: :ok
  defp validate_stdin_available(value), do: {:error, {:invalid_stdin, value}}

  defp validate_transport_module(module) when is_atom(module) do
    callbacks = [
      {:start, 1},
      {:start_link, 1},
      {:send, 2},
      {:end_input, 1},
      {:close, 1},
      {:force_close, 1},
      {:interrupt, 1},
      {:status, 1},
      {:stderr, 1},
      {:info, 1}
    ]

    if Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end) do
      :ok
    else
      {:error, {:invalid_transport_module, module}}
    end
  end

  defp validate_transport_module(module), do: {:error, {:invalid_transport_module, module}}
end
