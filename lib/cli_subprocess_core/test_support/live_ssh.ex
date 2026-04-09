defmodule CliSubprocessCore.TestSupport.LiveSSH do
  @moduledoc """
  Shared env-driven helpers for opt-in live SSH execution-surface tests.

  Environment variables:

  - `CLI_SUBPROCESS_CORE_LIVE_SSH=1` enables the helpers
  - `CLI_SUBPROCESS_CORE_LIVE_SSH_DESTINATION=<host>` selects the SSH target
  - optional `CLI_SUBPROCESS_CORE_LIVE_SSH_USER`
  - optional `CLI_SUBPROCESS_CORE_LIVE_SSH_PORT`
  - optional `CLI_SUBPROCESS_CORE_LIVE_SSH_IDENTITY_FILE`
  - optional `CLI_SUBPROCESS_CORE_LIVE_SSH_PATH`
  - optional provider command overrides such as
    `CLI_SUBPROCESS_CORE_LIVE_SSH_CLAUDE_COMMAND=/path/to/claude`
  """

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Command.RunResult
  alias CliSubprocessCore.ExecutionSurface
  alias ExternalRuntimeTransport.ProcessExit

  @enabled_env "CLI_SUBPROCESS_CORE_LIVE_SSH"
  @destination_env "CLI_SUBPROCESS_CORE_LIVE_SSH_DESTINATION"
  @user_env "CLI_SUBPROCESS_CORE_LIVE_SSH_USER"
  @port_env "CLI_SUBPROCESS_CORE_LIVE_SSH_PORT"
  @identity_file_env "CLI_SUBPROCESS_CORE_LIVE_SSH_IDENTITY_FILE"
  @ssh_path_env "CLI_SUBPROCESS_CORE_LIVE_SSH_PATH"
  @provider_command_env_prefix "CLI_SUBPROCESS_CORE_LIVE_SSH_"
  @default_timeout_ms 30_000

  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env(@enabled_env)
    |> to_string()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes"]))
  end

  @spec skip_reason() :: String.t()
  def skip_reason do
    "Live SSH tests are opt-in. Run with CLI_SUBPROCESS_CORE_LIVE_SSH=1 " <>
      "CLI_SUBPROCESS_CORE_LIVE_SSH_DESTINATION=<ssh-host> mix test --only live_ssh --include live_ssh"
  end

  @spec destination() :: String.t() | nil
  def destination do
    case System.get_env(@destination_env) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  @spec execution_surface(keyword()) :: ExecutionSurface.t()
  def execution_surface(opts \\ []) when is_list(opts) do
    transport_options =
      env_transport_options()
      |> Keyword.merge(Keyword.get(opts, :transport_options, []))

    surface_opts =
      [
        surface_kind: Keyword.get(opts, :surface_kind, :ssh_exec),
        transport_options: transport_options,
        target_id: Keyword.get(opts, :target_id),
        lease_ref: Keyword.get(opts, :lease_ref),
        surface_ref: Keyword.get(opts, :surface_ref),
        boundary_class: Keyword.get(opts, :boundary_class),
        observability: Keyword.get(opts, :observability, %{})
      ]

    case ExecutionSurface.new(surface_opts) do
      {:ok, %ExecutionSurface{} = surface} ->
        surface

      {:error, reason} ->
        raise ArgumentError, "invalid live SSH execution surface: #{inspect(reason)}"
    end
  end

  @spec execution_surface_options(keyword()) :: keyword()
  def execution_surface_options(opts \\ []) when is_list(opts) do
    surface = execution_surface(opts)

    surface
    |> ExecutionSurface.surface_metadata()
    |> Keyword.put(:transport_options, surface.transport_options)
  end

  @spec provider_command(:amp | :claude | :codex | :gemini) :: String.t() | nil
  def provider_command(provider) when provider in [:amp, :claude, :codex, :gemini] do
    case System.get_env(provider_command_env(provider)) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  @spec provider_command_env(:amp | :claude | :codex | :gemini) :: String.t()
  def provider_command_env(provider) when provider in [:amp, :claude, :codex, :gemini] do
    @provider_command_env_prefix <> String.upcase(Atom.to_string(provider)) <> "_COMMAND"
  end

  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, RunResult.t()} | {:error, term()}
  def run(command, args \\ [], opts \\ [])
      when is_binary(command) and is_list(args) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    invocation_opts =
      opts
      |> Keyword.take([:cwd, :env, :clear_env?, :user])
      |> Keyword.put_new(:env, %{})

    Command.run(
      Command.new(command, args, invocation_opts),
      execution_surface_options(opts) ++
        [
          timeout: timeout,
          stderr: :separate
        ]
    )
  end

  @dialyzer {:nowarn_function, runnable?: 3}
  @spec runnable?(String.t(), [String.t()], keyword()) :: boolean()
  def runnable?(command, args \\ ["--version"], opts \\ [])
      when is_binary(command) and is_list(args) and is_list(opts) do
    case run(command, args, opts) do
      {:ok, %RunResult{exit: %ProcessExit{status: :success}}} -> true
      _other -> false
    end
  end

  defp env_transport_options do
    destination =
      case destination() do
        nil -> raise ArgumentError, "missing #{@destination_env} for live SSH testing"
        value -> value
      end

    []
    |> Keyword.put(:destination, destination)
    |> maybe_put(@user_env, :ssh_user)
    |> maybe_put(@port_env, :port, &parse_port!/1)
    |> maybe_put(@identity_file_env, :identity_file)
    |> maybe_put(@ssh_path_env, :ssh_path)
  end

  defp maybe_put(opts, env_var, key, fun \\ & &1) when is_list(opts) and is_binary(env_var) do
    case System.get_env(env_var) do
      value when is_binary(value) and value != "" -> Keyword.put(opts, key, fun.(value))
      _other -> opts
    end
  end

  defp parse_port!(value) when is_binary(value) do
    case Integer.parse(value) do
      {port, ""} when port > 0 -> port
      _other -> raise ArgumentError, "invalid #{@port_env}: #{inspect(value)}"
    end
  end
end
