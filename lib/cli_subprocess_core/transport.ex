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
  subscription.
  """

  alias CliSubprocessCore.{Command, ProcessExit, Transport.Error}
  alias CliSubprocessCore.Transport.Erlexec
  alias CliSubprocessCore.Transport.Info
  alias CliSubprocessCore.Transport.RunResult

  @typedoc "Opaque transport reference."
  @type t :: pid()

  @typedoc "Legacy subscribers use `:legacy`; tagged subscribers use a reference."
  @type subscription_tag :: :legacy | reference()

  @typedoc "The tagged event atom prefix."
  @type event_tag :: atom()

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
  def start(opts), do: Erlexec.start(opts)

  @doc """
  Starts the default raw transport implementation and links it to the caller.
  """
  @spec start_link(keyword()) :: {:ok, t()} | {:error, {:transport, Error.t()}}
  def start_link(opts), do: Erlexec.start_link(opts)

  @doc """
  Runs a one-shot non-PTY command and captures exact stdout, stderr, and exit
  data.
  """
  @spec run(Command.t(), keyword()) :: {:ok, RunResult.t()} | {:error, {:transport, Error.t()}}
  def run(%Command{} = command, opts \\ []) when is_list(opts), do: Erlexec.run(command, opts)

  @doc """
  Sends data to the subprocess stdin.
  """
  @spec send(t(), iodata() | map() | list()) :: :ok | {:error, {:transport, Error.t()}}
  def send(transport, message), do: Erlexec.send(transport, message)

  @doc """
  Subscribes the caller in legacy mode.
  """
  @spec subscribe(t(), pid()) :: :ok | {:error, {:transport, Error.t()}}
  def subscribe(transport, pid), do: Erlexec.subscribe(transport, pid)

  @doc """
  Subscribes a process with an explicit tag mode.
  """
  @spec subscribe(t(), pid(), subscription_tag()) :: :ok | {:error, {:transport, Error.t()}}
  def subscribe(transport, pid, tag), do: Erlexec.subscribe(transport, pid, tag)

  @doc """
  Removes a subscriber.
  """
  @spec unsubscribe(t(), pid()) :: :ok
  def unsubscribe(transport, pid), do: Erlexec.unsubscribe(transport, pid)

  @doc """
  Stops the transport.
  """
  @spec close(t()) :: :ok
  def close(transport), do: Erlexec.close(transport)

  @doc """
  Forces the subprocess down immediately.
  """
  @spec force_close(t()) :: :ok | {:error, {:transport, Error.t()}}
  def force_close(transport), do: Erlexec.force_close(transport)

  @doc """
  Sends SIGINT to the subprocess.
  """
  @spec interrupt(t()) :: :ok | {:error, {:transport, Error.t()}}
  def interrupt(transport), do: Erlexec.interrupt(transport)

  @doc """
  Returns transport connectivity status.
  """
  @spec status(t()) :: :connected | :disconnected | :error
  def status(transport), do: Erlexec.status(transport)

  @doc """
  Closes stdin for EOF-driven CLIs.
  """
  @spec end_input(t()) :: :ok | {:error, {:transport, Error.t()}}
  def end_input(transport), do: Erlexec.end_input(transport)

  @doc """
  Returns the stderr ring buffer tail.
  """
  @spec stderr(t()) :: binary()
  def stderr(transport), do: Erlexec.stderr(transport)

  @doc """
  Returns the current transport metadata snapshot.
  """
  @spec info(t()) :: Info.t()
  def info(transport), do: Erlexec.info(transport)
end
