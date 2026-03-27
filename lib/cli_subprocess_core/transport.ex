defmodule CliSubprocessCore.Transport do
  @moduledoc """
  Behaviour for the raw subprocess transport layer.

  In addition to the long-lived subscriber-driven transport API, the transport
  layer also owns synchronous non-PTY command execution through `run/2`.

  Legacy subscribers receive bare transport tuples:

  - `{:transport_message, line}`
  - `{:transport_data, chunk}`
  - `{:transport_error, %CliSubprocessCore.Transport.Error{}}`
  - `{:transport_stderr, chunk}`
  - `{:transport_exit, %CliSubprocessCore.ProcessExit{}}`

  Tagged subscribers receive:

  - `{event_tag, ref, {:message, line}}`
  - `{event_tag, ref, {:data, chunk}}`
  - `{event_tag, ref, {:error, %CliSubprocessCore.Transport.Error{}}}`
  - `{event_tag, ref, {:stderr, chunk}}`
  - `{event_tag, ref, {:exit, %CliSubprocessCore.ProcessExit{}}}`

  When `:replay_stderr_on_subscribe?` is enabled at startup, newly attached
  subscribers also receive the retained stderr tail immediately after
  subscription. When `:buffer_events_until_subscribe?` is enabled, stdout,
  stderr, and error events emitted before the first subscriber attaches are
  replayed in order.
  """

  alias CliSubprocessCore.{Command, ProcessExit, TaskSupport, Transport.Error}
  alias CliSubprocessCore.Transport.Delivery
  alias CliSubprocessCore.Transport.ExecutionSurface
  alias CliSubprocessCore.Transport.Info
  alias CliSubprocessCore.Transport.RunResult

  @default_call_timeout_ms 5_000
  @default_force_close_timeout_ms 5_000

  @typedoc "Opaque transport reference."
  @type t :: pid()

  @typedoc "Legacy subscribers use `:legacy`; tagged subscribers use a reference."
  @type subscription_tag :: :legacy | reference()

  @typedoc "The tagged event atom prefix."
  @type event_tag :: atom()

  @typedoc "Generic execution-surface placement kind."
  @type surface_kind :: :local_subprocess | :static_ssh | :leased_ssh | :guest_bridge

  @typedoc "Transport events delivered to subscribers."
  @type message ::
          {:transport_message, binary()}
          | {:transport_data, binary()}
          | {:transport_error, Error.t()}
          | {:transport_stderr, binary()}
          | {:transport_exit, ProcessExit.t()}
          | {event_tag(), reference(), {:message, binary()}}
          | {event_tag(), reference(), {:data, binary()}}
          | {event_tag(), reference(), {:error, Error.t()}}
          | {event_tag(), reference(), {:stderr, binary()}}
          | {event_tag(), reference(), {:exit, ProcessExit.t()}}

  @typedoc "Normalized transport event payload extracted from a mailbox message."
  @type extracted_event ::
          {:message, binary()}
          | {:data, binary()}
          | {:error, Error.t()}
          | {:stderr, binary()}
          | {:exit, ProcessExit.t()}

  @callback start(keyword()) :: {:ok, t()} | {:error, {:transport, Error.t()}}
  @callback start_link(keyword()) :: {:ok, t()} | {:error, {:transport, Error.t()}}
  @callback run(Command.t(), keyword()) ::
              {:ok, RunResult.t()} | {:error, {:transport, Error.t()}}
  @callback send(t(), iodata() | map() | list()) :: :ok | {:error, {:transport, Error.t()}}
  @callback subscribe(t(), pid()) :: :ok | {:error, {:transport, Error.t()}}
  @callback subscribe(t(), pid(), subscription_tag()) ::
              :ok | {:error, {:transport, Error.t()}}
  @callback unsubscribe(t(), pid()) :: :ok
  @callback close(t()) :: :ok
  @callback force_close(t()) :: :ok | {:error, {:transport, Error.t()}}
  @callback interrupt(t()) :: :ok | {:error, {:transport, Error.t()}}
  @callback status(t()) :: :connected | :disconnected | :error
  @callback end_input(t()) :: :ok | {:error, {:transport, Error.t()}}
  @callback stderr(t()) :: binary()
  @callback info(t()) :: Info.t()

  @doc """
  Starts the default raw transport implementation.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, {:transport, Error.t()}}
  def start(opts) when is_list(opts) do
    case ExecutionSurface.resolve(opts) do
      {:ok, %{dispatch: dispatch, adapter_options: adapter_options}} ->
        dispatch.start.(adapter_options)

      {:error, reason} ->
        transport_error(reason)
    end
  end

  @doc """
  Starts the default raw transport implementation and links it to the caller.
  """
  @spec start_link(keyword()) :: {:ok, t()} | {:error, {:transport, Error.t()}}
  def start_link(opts) when is_list(opts) do
    case ExecutionSurface.resolve(opts) do
      {:ok, %{dispatch: dispatch, adapter_options: adapter_options}} ->
        dispatch.start_link.(adapter_options)

      {:error, reason} ->
        transport_error(reason)
    end
  end

  @doc """
  Runs a one-shot non-PTY command and captures exact stdout, stderr, and exit
  data.
  """
  @spec run(Command.t(), keyword()) :: {:ok, RunResult.t()} | {:error, {:transport, Error.t()}}
  def run(%Command{} = command, opts \\ []) when is_list(opts) do
    case ExecutionSurface.resolve(opts) do
      {:ok, %{dispatch: dispatch, adapter_options: adapter_options}} ->
        dispatch.run.(command, adapter_options)

      {:error, reason} ->
        transport_error(reason)
    end
  end

  @doc """
  Sends data to the subprocess stdin.
  """
  @spec send(t(), iodata() | map() | list()) :: :ok | {:error, {:transport, Error.t()}}
  def send(transport, message) when is_pid(transport) do
    case safe_call(transport, {:send, message}) do
      {:ok, result} -> result
      {:error, reason} -> transport_error(reason)
    end
  end

  @doc """
  Subscribes the caller in legacy mode.
  """
  @spec subscribe(t(), pid()) :: :ok | {:error, {:transport, Error.t()}}
  def subscribe(transport, pid) when is_pid(transport) and is_pid(pid) do
    subscribe(transport, pid, :legacy)
  end

  @doc """
  Subscribes a process with an explicit tag mode.
  """
  @spec subscribe(t(), pid(), subscription_tag()) :: :ok | {:error, {:transport, Error.t()}}
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

  @doc """
  Removes a subscriber.
  """
  @spec unsubscribe(t(), pid()) :: :ok
  def unsubscribe(transport, pid) when is_pid(transport) and is_pid(pid) do
    case safe_call(transport, {:unsubscribe, pid}) do
      {:ok, :ok} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Stops the transport.
  """
  @spec close(t()) :: :ok
  def close(transport) when is_pid(transport) do
    GenServer.stop(transport, :normal)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, :noproc -> :ok
  end

  @doc """
  Forces the subprocess down immediately.
  """
  @spec force_close(t()) :: :ok | {:error, {:transport, Error.t()}}
  def force_close(transport) when is_pid(transport) do
    do_force_close(transport, @default_force_close_timeout_ms)
  end

  @doc """
  Sends SIGINT to the subprocess.
  """
  @spec interrupt(t()) :: :ok | {:error, {:transport, Error.t()}}
  def interrupt(transport) when is_pid(transport) do
    case safe_call(transport, :interrupt) do
      {:ok, result} ->
        normalize_call_result(result)

      {:error, reason} ->
        transport_error(reason)
    end
  end

  @doc """
  Returns transport connectivity status.
  """
  @spec status(t()) :: :connected | :disconnected | :error
  def status(transport) when is_pid(transport) do
    case safe_call(transport, :status) do
      {:ok, status} when status in [:connected, :disconnected, :error] -> status
      {:ok, _other} -> :error
      {:error, _reason} -> :disconnected
    end
  end

  @doc """
  Closes stdin for EOF-driven CLIs.

  Pipe-backed transports send `:eof`; PTY-backed transports send the terminal
  EOF byte (`Ctrl-D`).
  """
  @spec end_input(t()) :: :ok | {:error, {:transport, Error.t()}}
  def end_input(transport) when is_pid(transport) do
    case safe_call(transport, :end_input) do
      {:ok, result} -> result
      {:error, reason} -> transport_error(reason)
    end
  end

  @doc """
  Returns the stderr ring buffer tail.
  """
  @spec stderr(t()) :: binary()
  def stderr(transport) when is_pid(transport) do
    case safe_call(transport, :stderr) do
      {:ok, data} when is_binary(data) -> data
      _ -> ""
    end
  end

  @doc """
  Returns the current transport metadata snapshot.
  """
  @spec info(t()) :: Info.t()
  def info(transport) when is_pid(transport) do
    case safe_call(transport, :info) do
      {:ok, %Info{} = info} -> info
      _other -> Info.disconnected()
    end
  end

  @doc """
  Extracts a normalized transport event from a legacy mailbox message.

  Tagged subscribers should use `extract_event/2` so their code does not depend
  on a specific outer event tag.
  """
  @spec extract_event(term()) :: {:ok, extracted_event()} | :error
  def extract_event({:transport_message, line}) when is_binary(line), do: {:ok, {:message, line}}
  def extract_event({:transport_data, chunk}) when is_binary(chunk), do: {:ok, {:data, chunk}}
  def extract_event({:transport_error, %Error{} = error}), do: {:ok, {:error, error}}
  def extract_event({:transport_stderr, chunk}) when is_binary(chunk), do: {:ok, {:stderr, chunk}}
  def extract_event({:transport_exit, %ProcessExit{} = exit}), do: {:ok, {:exit, exit}}
  def extract_event(_message), do: :error

  @doc """
  Extracts a normalized transport event for a tagged subscriber reference.

  This is the stable core-owned way for adapters to consume tagged transport
  delivery without hard-coding the configured outer event atom.
  """
  @spec extract_event(term(), reference()) :: {:ok, extracted_event()} | :error
  def extract_event({event_tag, ref, event}, ref) when is_atom(event_tag) do
    extract_tagged_event(event)
  end

  def extract_event(message, _ref), do: extract_event(message)

  @doc """
  Returns stable mailbox-delivery metadata for the current transport snapshot.
  """
  @spec delivery_info(t()) :: Delivery.t()
  def delivery_info(transport) do
    case info(transport) do
      %Info{delivery: %Delivery{} = delivery} -> delivery
      _other -> Delivery.new(:cli_subprocess_core)
    end
  end

  defp extract_tagged_event({:message, line}) when is_binary(line), do: {:ok, {:message, line}}
  defp extract_tagged_event({:data, chunk}) when is_binary(chunk), do: {:ok, {:data, chunk}}
  defp extract_tagged_event({:error, %Error{} = error}), do: {:ok, {:error, error}}
  defp extract_tagged_event({:stderr, chunk}) when is_binary(chunk), do: {:ok, {:stderr, chunk}}
  defp extract_tagged_event({:exit, %ProcessExit{} = exit}), do: {:ok, {:exit, exit}}
  defp extract_tagged_event(_event), do: :error

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

  defp do_force_close(transport, timeout_ms)
       when is_pid(transport) and is_integer(timeout_ms) and timeout_ms >= 0 do
    GenServer.stop(transport, :normal, timeout_ms)
    :ok
  catch
    :exit, reason ->
      transport_error(normalize_force_close_exit(reason))
  end

  defp normalize_force_close_exit({:noproc, _}), do: Error.not_connected()
  defp normalize_force_close_exit(:noproc), do: Error.not_connected()
  defp normalize_force_close_exit({:normal, _}), do: Error.not_connected()
  defp normalize_force_close_exit({:shutdown, _}), do: Error.not_connected()
  defp normalize_force_close_exit({:timeout, {GenServer, :stop, _}}), do: Error.timeout()
  defp normalize_force_close_exit({:timeout, _}), do: Error.timeout()
  defp normalize_force_close_exit(reason), do: Error.call_exit(reason)

  defp transport_error({:transport, %Error{}} = error), do: {:error, error}
  defp transport_error(%Error{} = error), do: {:error, {:transport, error}}
  defp transport_error(reason), do: {:error, {:transport, Error.transport_error(reason)}}
end
