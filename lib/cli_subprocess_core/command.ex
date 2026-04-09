defmodule CliSubprocessCore.Command do
  @moduledoc """
  Normalized subprocess invocation data shared by provider profiles.

  The module also exposes the shared provider-aware one-shot command lane
  through `run/1` and `run/2`.
  """

  alias CliSubprocessCore.Command.{Error, Options, RunResult}
  alias CliSubprocessCore.{CommandSpec, ProviderProfile, ProviderRegistry, TransportCompat}
  alias ExecutionPlane.Command, as: RuntimeCommand
  alias ExecutionPlane.Process, as: ExecutionPlaneProcess
  alias ExecutionPlane.Process.Transport, as: RuntimeTransport
  alias ExternalRuntimeTransport.Command, as: TransportCommand
  alias ExternalRuntimeTransport.ProcessExit
  alias ExternalRuntimeTransport.Transport.Error, as: TransportError

  @enforce_keys [:command]
  defstruct command: nil, args: [], cwd: nil, env: %{}, clear_env?: false, user: nil

  @type env_key :: String.t()
  @type env_value :: String.t()
  @type env_map :: %{optional(env_key()) => env_value()}
  @type user :: String.t() | nil

  @type t :: %__MODULE__{
          command: String.t(),
          args: [String.t()],
          cwd: String.t() | nil,
          env: env_map(),
          clear_env?: boolean(),
          user: user()
        }

  @type run_result :: RunResult.t()
  @type run_error :: CliSubprocessCore.Command.Error.t()

  @doc """
  Builds a normalized invocation struct.
  """
  @spec new(String.t() | CommandSpec.t(), [String.t()] | keyword(), keyword()) :: t()
  def new(command, args \\ [], opts \\ [])
      when (is_binary(command) or is_struct(command, CommandSpec)) and is_list(args) and
             is_list(opts) do
    {args, opts} =
      if opts == [] and keyword_list?(args) do
        {[], args}
      else
        {args, opts}
      end

    {command, args} =
      case command do
        %CommandSpec{} = spec ->
          {spec.program, CommandSpec.command_args(spec, args)}

        binary when is_binary(binary) ->
          {binary, args}
      end

    %__MODULE__{
      command: command,
      args: args,
      cwd: Keyword.get(opts, :cwd),
      env: normalize_env(Keyword.get(opts, :env, %{})),
      clear_env?: Keyword.get(opts, :clear_env?, false),
      user: normalize_user(Keyword.get(opts, :user))
    }
  end

  @doc """
  Returns the executable and arguments as an argv list.
  """
  @spec argv(t()) :: [String.t()]
  def argv(%__MODULE__{} = command) do
    [command.command | command.args]
  end

  @doc """
  Projects a CLI-domain invocation onto the generic transport substrate.
  """
  @spec to_transport_command(t()) :: TransportCommand.t()
  def to_transport_command(%__MODULE__{} = command) do
    TransportCommand.new(command.command, command.args,
      cwd: command.cwd,
      env: command.env,
      clear_env?: command.clear_env?,
      user: command.user
    )
  end

  @doc """
  Projects a CLI-domain invocation onto either the Execution Plane or legacy
  compatibility transport command shape.
  """
  @spec to_runtime_command(t(), module()) :: term()
  def to_runtime_command(%__MODULE__{} = command, ExecutionPlane.Process.Transport) do
    %RuntimeCommand{
      command: command.command,
      args: command.args,
      cwd: command.cwd,
      env: command.env,
      clear_env?: command.clear_env?,
      user: command.user
    }
  end

  def to_runtime_command(%__MODULE__{} = command, _transport_api) do
    to_transport_command(command)
  end

  @doc """
  Runs a provider-aware one-shot command through the shared transport-owned
  non-PTY lane.

  Reserved command-lane options are:

  - `:provider`
  - `:profile`
  - `:registry`
  - `:stdin`
  - `:timeout`
  - `:stderr`
  - `:close_stdin`

  All remaining options are passed through to the resolved provider profile's
  `build_invocation/1` callback.
  """
  @spec run(keyword()) :: {:ok, run_result()} | {:error, run_error()}
  def run(opts) when is_list(opts) do
    case Options.new(opts) do
      {:ok, options} ->
        with {:ok, invocation} <- resolve_invocation(options) do
          do_run(invocation, options)
        end

      {:error, reason} ->
        {:error, Error.invalid_options(reason)}
    end
  end

  @doc """
  Runs a prebuilt normalized invocation through the shared non-PTY command
  lane.
  """
  @spec run(t(), keyword()) :: {:ok, run_result()} | {:error, run_error()}
  def run(%__MODULE__{} = invocation, opts) when is_list(opts) do
    case Options.new(invocation, opts) do
      {:ok, options} ->
        do_run(invocation, options)

      {:error, reason} ->
        {:error, Error.invalid_options(reason, %{invocation: invocation})}
    end
  end

  @doc """
  Adds or replaces a single environment variable.
  """
  @spec put_env(t(), String.t() | atom(), String.t() | atom() | number() | boolean()) :: t()
  def put_env(%__MODULE__{} = command, key, value) do
    merge_env(command, %{normalize_env_key(key) => normalize_env_value(value)})
  end

  @doc """
  Merges environment variables into the invocation.
  """
  @spec merge_env(t(), map()) :: t()
  def merge_env(%__MODULE__{} = command, env) when is_map(env) do
    merged =
      command.env
      |> Map.merge(normalize_env(env))

    %{command | env: merged}
  end

  @doc """
  Validates the invocation contract expected by the provider profile behaviour.
  """
  @spec validate(t()) ::
          :ok
          | {:error, {:invalid_command, term()}}
          | {:error, {:invalid_args, term()}}
          | {:error, {:invalid_cwd, term()}}
          | {:error, {:invalid_env, term()}}
          | {:error, {:invalid_clear_env, term()}}
          | {:error, {:invalid_user, term()}}
  def validate(%__MODULE__{
        command: command,
        args: args,
        cwd: cwd,
        env: env,
        clear_env?: clear_env?,
        user: user
      }) do
    validators = [
      fn -> validate_command(command) end,
      fn -> validate_args(args) end,
      fn -> validate_cwd(cwd) end,
      fn -> validate_env(env) end,
      fn -> validate_clear_env(clear_env?) end,
      fn -> validate_user(user) end
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.() do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_invocation(%Options{profile: profile} = options)
       when is_atom(profile) and not is_nil(profile) do
    build_invocation(profile, Options.provider_profile_options(options), options.provider)
  end

  defp resolve_invocation(%Options{provider: provider, registry: registry} = options) do
    case ProviderRegistry.fetch(provider, registry) do
      {:ok, profile} ->
        build_invocation(profile, Options.provider_profile_options(options), provider)

      :error ->
        {:error, Error.provider_not_found(provider)}
    end
  catch
    :exit, reason ->
      {:error, Error.command_plan_failed(reason, %{provider: provider, registry: registry})}
  end

  defp build_invocation(profile, provider_options, provider) do
    with {:ok, invocation} <- profile.build_invocation(provider_options),
         :ok <- ProviderProfile.validate_invocation(invocation) do
      {:ok, invocation}
    else
      {:error, reason} ->
        {:error, Error.command_plan_failed(reason, %{provider: provider, profile: profile})}
    end
  end

  defp do_run(invocation, %Options{surface_kind: :local_subprocess} = options) do
    execution_surface = Options.execution_surface(options)

    invocation
    |> execution_plane_request(options, execution_surface)
    |> ExecutionPlaneProcess.run()
    |> normalize_execution_plane_run(invocation, options, execution_surface)
  end

  defp do_run(invocation, %Options{} = options) do
    execution_surface = Options.execution_surface(options)
    runtime_execution_surface = Options.runtime_execution_surface(options)
    runtime_invocation = to_runtime_command(invocation, RuntimeTransport)

    case RuntimeTransport.run(runtime_invocation,
           stdin: options.stdin,
           timeout: options.timeout,
           stderr: options.stderr,
           close_stdin: options.close_stdin,
           execution_surface: runtime_execution_surface,
           transport_options: options.transport_options,
           target_id: execution_surface.target_id,
           lease_ref: execution_surface.lease_ref,
           surface_ref: execution_surface.surface_ref,
           boundary_class: execution_surface.boundary_class,
           observability: execution_surface.observability
         ) do
      {:ok, result} ->
        {:ok, RunResult.from_transport(result, invocation)}

      {:error, {:transport, error}} ->
        transport_error = TransportCompat.to_transport_error(error)
        {:error, Error.transport_error(transport_error, %{invocation: invocation})}
    end
  end

  defp execution_plane_request(invocation, %Options{} = options, execution_surface) do
    %{
      command: invocation.command,
      argv: invocation.args,
      cwd: invocation.cwd,
      env: invocation.env,
      clear_env: invocation.clear_env?,
      user: invocation.user,
      stdin: options.stdin,
      stderr_mode: Atom.to_string(options.stderr),
      close_stdin: options.close_stdin,
      timeout_ms: options.timeout,
      execution_surface: %{surface_kind: Atom.to_string(execution_surface.surface_kind)},
      target_id: execution_surface.target_id
    }
  end

  defp normalize_execution_plane_run({:ok, result}, invocation, %Options{} = options, _surface) do
    {:ok, execution_plane_run_result(result, invocation, options)}
  end

  defp normalize_execution_plane_run(
         {:error, %{outcome: %{failure: nil}} = result},
         invocation,
         %Options{} = options,
         _surface
       ) do
    {:ok, execution_plane_run_result(result, invocation, options)}
  end

  defp normalize_execution_plane_run(
         {:error, %{outcome: %{failure: failure, raw_payload: raw_payload}}},
         invocation,
         _options,
         execution_surface
       ) do
    error =
      failure
      |> execution_plane_transport_error(raw_payload, execution_surface)
      |> Error.transport_error(%{invocation: invocation})

    {:error, error}
  end

  defp execution_plane_run_result(result, invocation, %Options{} = options) do
    raw_payload = result.outcome.raw_payload

    %RunResult{
      invocation: invocation,
      output: Map.get(raw_payload, :output, ""),
      stdout: Map.get(raw_payload, :stdout, ""),
      stderr: Map.get(raw_payload, :stderr, ""),
      exit: normalize_execution_plane_exit(Map.get(raw_payload, :exit, %{})),
      stderr_mode: options.stderr
    }
  end

  defp normalize_execution_plane_exit(exit) when is_map(exit) do
    %ProcessExit{
      status: Map.get(exit, :status) || Map.get(exit, "status") || :error,
      code: Map.get(exit, :code) || Map.get(exit, "code"),
      signal: Map.get(exit, :signal) || Map.get(exit, "signal"),
      reason: Map.get(exit, :reason) || Map.get(exit, "reason"),
      stderr: Map.get(exit, :stderr) || Map.get(exit, "stderr")
    }
  end

  defp execution_plane_transport_error(failure, raw_payload, execution_surface) do
    context = %{
      failure_class: failure.failure_class,
      raw_payload: raw_payload,
      surface_kind: execution_surface.surface_kind
    }

    case {failure.failure_class, raw_payload} do
      {:timeout, _payload} ->
        TransportError.transport_error(:timeout, context)

      {_, %{send_failed: reason}} ->
        TransportError.transport_error({:send_failed, reason}, context)

      {_, %{command: command}} when is_binary(command) ->
        TransportError.transport_error({:command_not_found, command}, context)

      {_, %{cwd: cwd}} when is_binary(cwd) ->
        TransportError.transport_error({:cwd_not_found, cwd}, context)

      _other ->
        TransportError.transport_error(
          {:startup_failed, failure.reason || failure.failure_class},
          context
        )
    end
  end

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} ->
      {normalize_env_key(key), normalize_env_value(value)}
    end)
  end

  defp normalize_env(_other), do: %{}

  defp normalize_env_key(key) when is_binary(key), do: key
  defp normalize_env_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_env_key(key), do: to_string(key)

  defp normalize_env_value(value) when is_binary(value), do: value
  defp normalize_env_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_env_value(value) when is_boolean(value), do: to_string(value)
  defp normalize_env_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_env_value(value) when is_float(value), do: Float.to_string(value)

  defp validate_command(command) when is_binary(command) and command != "", do: :ok
  defp validate_command(command), do: {:error, {:invalid_command, command}}

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

  defp keyword_list?([]), do: true

  defp keyword_list?(list) when is_list(list) do
    Enum.all?(list, fn
      {key, _value} when is_atom(key) -> true
      _other -> false
    end)
  end

  defp normalize_user(nil), do: nil
  defp normalize_user(user) when is_binary(user), do: user
  defp normalize_user(user), do: to_string(user)

  defp validate_user(nil), do: :ok
  defp validate_user(user) when is_binary(user) and user != "", do: :ok
  defp validate_user(user), do: {:error, {:invalid_user, user}}
end
