defmodule CliSubprocessCore.Transport.Options do
  @moduledoc """
  Normalized startup options for the raw transport layer.
  """

  alias CliSubprocessCore.{Command, Transport}
  alias CliSubprocessCore.Transport.ExecutionSurface

  @default_event_tag :cli_subprocess_core
  @default_headless_timeout_ms 30_000
  @default_max_buffer_size 1_048_576
  @default_max_stderr_buffer_size 262_144
  @default_max_buffered_events 128
  @default_startup_mode :eager
  @default_task_supervisor CliSubprocessCore.TaskSupervisor
  @default_stdout_mode :line
  @default_stdin_mode :line
  @default_close_stdin_on_start? false

  @enforce_keys [:command]
  defstruct [
    :command,
    :surface_kind,
    :target_id,
    :lease_ref,
    :surface_ref,
    :boundary_class,
    :observability,
    adapter_metadata: %{},
    invocation_override: nil,
    args: [],
    cwd: nil,
    env: %{},
    clear_env?: false,
    user: nil,
    stdout_mode: @default_stdout_mode,
    stdin_mode: @default_stdin_mode,
    pty?: false,
    interrupt_mode: :signal,
    subscriber: nil,
    startup_mode: @default_startup_mode,
    task_supervisor: @default_task_supervisor,
    event_tag: @default_event_tag,
    headless_timeout_ms: @default_headless_timeout_ms,
    max_buffer_size: @default_max_buffer_size,
    max_stderr_buffer_size: @default_max_stderr_buffer_size,
    max_buffered_events: @default_max_buffered_events,
    stderr_callback: nil,
    close_stdin_on_start?: @default_close_stdin_on_start?,
    replay_stderr_on_subscribe?: false,
    buffer_events_until_subscribe?: false
  ]

  @type subscriber :: pid() | {pid(), Transport.subscription_tag()} | nil

  @type t :: %__MODULE__{
          command: String.t(),
          surface_kind: Transport.surface_kind(),
          target_id: String.t() | nil,
          lease_ref: String.t() | nil,
          surface_ref: String.t() | nil,
          boundary_class: atom() | nil,
          observability: map(),
          adapter_metadata: map(),
          invocation_override: Command.t() | nil,
          args: [String.t()],
          cwd: String.t() | nil,
          env: Command.env_map(),
          clear_env?: boolean(),
          user: Command.user(),
          stdout_mode: :line | :raw,
          stdin_mode: :line | :raw,
          pty?: boolean(),
          interrupt_mode: :signal | {:stdin, binary()},
          subscriber: subscriber(),
          startup_mode: :eager | :lazy,
          task_supervisor: pid() | atom(),
          event_tag: atom(),
          headless_timeout_ms: pos_integer() | :infinity,
          max_buffer_size: pos_integer(),
          max_stderr_buffer_size: pos_integer(),
          max_buffered_events: pos_integer(),
          stderr_callback: (binary() -> any()) | nil,
          close_stdin_on_start?: boolean(),
          replay_stderr_on_subscribe?: boolean(),
          buffer_events_until_subscribe?: boolean()
        }

  @type validation_error ::
          :missing_command
          | {:invalid_surface_kind, term()}
          | {:invalid_target_id, term()}
          | {:invalid_lease_ref, term()}
          | {:invalid_surface_ref, term()}
          | {:invalid_boundary_class, term()}
          | {:invalid_observability, term()}
          | {:invalid_command, term()}
          | {:invalid_args, term()}
          | {:invalid_cwd, term()}
          | {:invalid_env, term()}
          | {:invalid_clear_env, term()}
          | {:invalid_user, term()}
          | {:invalid_stdout_mode, term()}
          | {:invalid_stdin_mode, term()}
          | {:invalid_pty, term()}
          | {:invalid_interrupt_mode, term()}
          | {:invalid_subscriber, term()}
          | {:invalid_startup_mode, term()}
          | {:invalid_task_supervisor, term()}
          | {:invalid_event_tag, term()}
          | {:invalid_headless_timeout_ms, term()}
          | {:invalid_max_buffer_size, term()}
          | {:invalid_max_stderr_buffer_size, term()}
          | {:invalid_max_buffered_events, term()}
          | {:invalid_stderr_callback, term()}
          | {:invalid_close_stdin_on_start, term()}
          | {:invalid_replay_stderr_on_subscribe, term()}
          | {:invalid_buffer_events_until_subscribe, term()}

  @doc """
  Builds a validated transport options struct.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, {:invalid_transport_options, validation_error()}}
  def new(opts) when is_list(opts) do
    with {:ok, normalized} <- normalize_invocation(opts),
         {:ok, surface} <- normalize_surface(opts),
         :ok <- validate_surface_kind(surface.surface_kind),
         :ok <- validate_command(normalized.command),
         :ok <- validate_args(normalized.args),
         :ok <- validate_cwd(normalized.cwd),
         :ok <- validate_env(normalized.env),
         :ok <- validate_clear_env(normalized.clear_env?),
         :ok <- validate_user(normalized.user),
         :ok <- validate_stdout_mode(normalized.stdout_mode),
         :ok <- validate_stdin_mode(normalized.stdin_mode),
         :ok <- validate_pty(normalized.pty?),
         :ok <- validate_interrupt_mode(normalized.interrupt_mode),
         :ok <- validate_subscriber(normalized.subscriber),
         :ok <- validate_startup_mode(normalized.startup_mode),
         :ok <- validate_task_supervisor(normalized.task_supervisor),
         :ok <- validate_event_tag(normalized.event_tag),
         :ok <- validate_headless_timeout_ms(normalized.headless_timeout_ms),
         :ok <- validate_max_buffer_size(normalized.max_buffer_size),
         :ok <- validate_max_stderr_buffer_size(normalized.max_stderr_buffer_size),
         :ok <- validate_max_buffered_events(normalized.max_buffered_events),
         :ok <- validate_stderr_callback(normalized.stderr_callback),
         :ok <- validate_close_stdin_on_start(normalized.close_stdin_on_start?),
         :ok <- validate_replay_stderr_on_subscribe(normalized.replay_stderr_on_subscribe?),
         :ok <-
           validate_buffer_events_until_subscribe(normalized.buffer_events_until_subscribe?) do
      {:ok,
       struct!(
         __MODULE__,
         normalized
         |> Map.merge(surface_metadata(surface))
         |> Map.put(
           :adapter_metadata,
           normalize_adapter_metadata(Keyword.get(opts, :adapter_metadata))
         )
         |> Map.put(
           :invocation_override,
           normalize_invocation_override(Keyword.get(opts, :invocation_override))
         )
       )}
    else
      {:error, reason} -> {:error, {:invalid_transport_options, reason}}
    end
  end

  @doc """
  Builds a validated transport options struct or raises.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    case new(opts) do
      {:ok, options} ->
        options

      {:error, {:invalid_transport_options, reason}} ->
        raise ArgumentError, "invalid transport options: #{inspect(reason)}"
    end
  end

  @doc false
  def default_event_tag, do: @default_event_tag

  @doc false
  def default_headless_timeout_ms, do: @default_headless_timeout_ms

  @doc false
  def default_max_buffer_size, do: @default_max_buffer_size

  @doc false
  def default_max_stderr_buffer_size, do: @default_max_stderr_buffer_size

  defp normalize_invocation(opts) do
    case Keyword.get(opts, :command) do
      nil ->
        {:error, :missing_command}

      %Command{} = command ->
        {:ok,
         %{
           command: command.command,
           args: Keyword.get(opts, :args, command.args),
           cwd: Keyword.get(opts, :cwd, command.cwd),
           env: normalize_env(Keyword.get(opts, :env, command.env)),
           clear_env?: Keyword.get(opts, :clear_env?, command.clear_env?),
           user: Keyword.get(opts, :user, command.user),
           stdout_mode: Keyword.get(opts, :stdout_mode, @default_stdout_mode),
           stdin_mode: Keyword.get(opts, :stdin_mode, @default_stdin_mode),
           pty?: Keyword.get(opts, :pty?, false),
           interrupt_mode:
             normalize_interrupt_mode(
               Keyword.get(
                 opts,
                 :interrupt_mode,
                 default_interrupt_mode(Keyword.get(opts, :pty?, false))
               )
             ),
           subscriber: Keyword.get(opts, :subscriber),
           startup_mode: Keyword.get(opts, :startup_mode, @default_startup_mode),
           task_supervisor: Keyword.get(opts, :task_supervisor, @default_task_supervisor),
           event_tag: Keyword.get(opts, :event_tag, @default_event_tag),
           headless_timeout_ms:
             Keyword.get(opts, :headless_timeout_ms, @default_headless_timeout_ms),
           max_buffer_size: Keyword.get(opts, :max_buffer_size, @default_max_buffer_size),
           max_stderr_buffer_size:
             Keyword.get(opts, :max_stderr_buffer_size, @default_max_stderr_buffer_size),
           max_buffered_events:
             Keyword.get(opts, :max_buffered_events, @default_max_buffered_events),
           stderr_callback: Keyword.get(opts, :stderr_callback),
           close_stdin_on_start?:
             Keyword.get(opts, :close_stdin_on_start?, @default_close_stdin_on_start?),
           replay_stderr_on_subscribe?: Keyword.get(opts, :replay_stderr_on_subscribe?, false),
           buffer_events_until_subscribe?:
             Keyword.get(opts, :buffer_events_until_subscribe?, false)
         }}

      command ->
        {:ok,
         %{
           command: command,
           args: Keyword.get(opts, :args, []),
           cwd: Keyword.get(opts, :cwd),
           env: normalize_env(Keyword.get(opts, :env, %{})),
           clear_env?: Keyword.get(opts, :clear_env?, false),
           user: Keyword.get(opts, :user),
           stdout_mode: Keyword.get(opts, :stdout_mode, @default_stdout_mode),
           stdin_mode: Keyword.get(opts, :stdin_mode, @default_stdin_mode),
           pty?: Keyword.get(opts, :pty?, false),
           interrupt_mode:
             normalize_interrupt_mode(
               Keyword.get(
                 opts,
                 :interrupt_mode,
                 default_interrupt_mode(Keyword.get(opts, :pty?, false))
               )
             ),
           subscriber: Keyword.get(opts, :subscriber),
           startup_mode: Keyword.get(opts, :startup_mode, @default_startup_mode),
           task_supervisor: Keyword.get(opts, :task_supervisor, @default_task_supervisor),
           event_tag: Keyword.get(opts, :event_tag, @default_event_tag),
           headless_timeout_ms:
             Keyword.get(opts, :headless_timeout_ms, @default_headless_timeout_ms),
           max_buffer_size: Keyword.get(opts, :max_buffer_size, @default_max_buffer_size),
           max_stderr_buffer_size:
             Keyword.get(opts, :max_stderr_buffer_size, @default_max_stderr_buffer_size),
           max_buffered_events:
             Keyword.get(opts, :max_buffered_events, @default_max_buffered_events),
           stderr_callback: Keyword.get(opts, :stderr_callback),
           close_stdin_on_start?:
             Keyword.get(opts, :close_stdin_on_start?, @default_close_stdin_on_start?),
           replay_stderr_on_subscribe?: Keyword.get(opts, :replay_stderr_on_subscribe?, false),
           buffer_events_until_subscribe?:
             Keyword.get(opts, :buffer_events_until_subscribe?, false)
         }}
    end
  end

  defp normalize_env(nil), do: %{}

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env(env) when is_list(env) do
    Enum.reduce(env, %{}, fn
      {key, value}, acc -> Map.put(acc, to_string(key), to_string(value))
      _other, acc -> acc
    end)
  end

  defp normalize_env(_other), do: :invalid_env

  defp normalize_surface(opts) when is_list(opts) do
    case ExecutionSurface.new(opts) do
      {:ok, surface} -> {:ok, surface}
      {:error, reason} -> {:error, reason}
    end
  end

  defp surface_metadata(%ExecutionSurface{} = surface) do
    %{
      surface_kind: surface.surface_kind,
      target_id: surface.target_id,
      lease_ref: surface.lease_ref,
      surface_ref: surface.surface_ref,
      boundary_class: surface.boundary_class,
      observability: surface.observability
    }
  end

  defp normalize_adapter_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_adapter_metadata(_other), do: %{}

  defp normalize_invocation_override(%Command{} = command), do: command
  defp normalize_invocation_override(_other), do: nil

  defp validate_command(command) when is_binary(command) and byte_size(command) > 0, do: :ok
  defp validate_command(command), do: {:error, {:invalid_command, command}}

  defp validate_surface_kind(surface_kind)
       when surface_kind in [:local_subprocess, :static_ssh, :leased_ssh],
       do: :ok

  defp validate_surface_kind(surface_kind), do: {:error, {:invalid_surface_kind, surface_kind}}

  defp validate_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      :ok
    else
      {:error, {:invalid_args, args}}
    end
  end

  defp validate_args(args), do: {:error, {:invalid_args, args}}

  defp validate_cwd(nil), do: :ok
  defp validate_cwd(cwd) when is_binary(cwd), do: :ok
  defp validate_cwd(cwd), do: {:error, {:invalid_cwd, cwd}}

  defp validate_env(:invalid_env), do: {:error, {:invalid_env, :invalid_env}}

  defp validate_env(env) when is_map(env) do
    if Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      :ok
    else
      {:error, {:invalid_env, env}}
    end
  end

  defp validate_env(env), do: {:error, {:invalid_env, env}}
  defp validate_clear_env(value) when is_boolean(value), do: :ok
  defp validate_clear_env(value), do: {:error, {:invalid_clear_env, value}}
  defp validate_user(nil), do: :ok
  defp validate_user(user) when is_binary(user) and user != "", do: :ok
  defp validate_user(user), do: {:error, {:invalid_user, user}}

  defp validate_stdout_mode(mode) when mode in [:line, :raw], do: :ok
  defp validate_stdout_mode(mode), do: {:error, {:invalid_stdout_mode, mode}}

  defp validate_stdin_mode(mode) when mode in [:line, :raw], do: :ok
  defp validate_stdin_mode(mode), do: {:error, {:invalid_stdin_mode, mode}}

  defp validate_pty(value) when is_boolean(value), do: :ok
  defp validate_pty(value), do: {:error, {:invalid_pty, value}}

  defp validate_interrupt_mode({:invalid_interrupt_mode, mode}),
    do: {:error, {:invalid_interrupt_mode, mode}}

  defp validate_interrupt_mode(:signal), do: :ok

  defp validate_interrupt_mode({:stdin, payload}) when is_binary(payload) and payload != "",
    do: :ok

  defp validate_interrupt_mode(mode), do: {:error, {:invalid_interrupt_mode, mode}}

  defp validate_subscriber(nil), do: :ok
  defp validate_subscriber(pid) when is_pid(pid), do: :ok

  defp validate_subscriber({pid, tag}) when is_pid(pid) and (tag == :legacy or is_reference(tag)),
    do: :ok

  defp validate_subscriber(subscriber), do: {:error, {:invalid_subscriber, subscriber}}

  defp validate_startup_mode(mode) when mode in [:eager, :lazy], do: :ok
  defp validate_startup_mode(mode), do: {:error, {:invalid_startup_mode, mode}}

  defp validate_task_supervisor(supervisor) when is_atom(supervisor) or is_pid(supervisor),
    do: :ok

  defp validate_task_supervisor(supervisor), do: {:error, {:invalid_task_supervisor, supervisor}}

  defp validate_event_tag(event_tag) when is_atom(event_tag), do: :ok
  defp validate_event_tag(event_tag), do: {:error, {:invalid_event_tag, event_tag}}

  defp validate_headless_timeout_ms(:infinity), do: :ok

  defp validate_headless_timeout_ms(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: :ok

  defp validate_headless_timeout_ms(timeout_ms),
    do: {:error, {:invalid_headless_timeout_ms, timeout_ms}}

  defp validate_max_buffer_size(size) when is_integer(size) and size > 0, do: :ok
  defp validate_max_buffer_size(size), do: {:error, {:invalid_max_buffer_size, size}}

  defp validate_max_stderr_buffer_size(size) when is_integer(size) and size > 0, do: :ok

  defp validate_max_stderr_buffer_size(size),
    do: {:error, {:invalid_max_stderr_buffer_size, size}}

  defp validate_max_buffered_events(size) when is_integer(size) and size > 0, do: :ok
  defp validate_max_buffered_events(size), do: {:error, {:invalid_max_buffered_events, size}}

  defp validate_stderr_callback(nil), do: :ok
  defp validate_stderr_callback(callback) when is_function(callback, 1), do: :ok
  defp validate_stderr_callback(callback), do: {:error, {:invalid_stderr_callback, callback}}

  defp validate_close_stdin_on_start(value) when is_boolean(value), do: :ok

  defp validate_close_stdin_on_start(value),
    do: {:error, {:invalid_close_stdin_on_start, value}}

  defp validate_replay_stderr_on_subscribe(value) when is_boolean(value), do: :ok

  defp validate_replay_stderr_on_subscribe(value),
    do: {:error, {:invalid_replay_stderr_on_subscribe, value}}

  defp validate_buffer_events_until_subscribe(value) when is_boolean(value), do: :ok

  defp validate_buffer_events_until_subscribe(value),
    do: {:error, {:invalid_buffer_events_until_subscribe, value}}

  defp default_interrupt_mode(true), do: {:stdin, <<3>>}
  defp default_interrupt_mode(_pty?), do: :signal

  defp normalize_interrupt_mode(:signal), do: :signal

  defp normalize_interrupt_mode({:stdin, payload}) do
    case normalize_interrupt_payload(payload) do
      {:ok, normalized} -> {:stdin, normalized}
      :error -> {:invalid_interrupt_mode, {:stdin, payload}}
    end
  end

  defp normalize_interrupt_mode(other), do: other

  defp normalize_interrupt_payload(payload) do
    {:ok, IO.iodata_to_binary(payload)}
  rescue
    _error -> :error
  end
end
