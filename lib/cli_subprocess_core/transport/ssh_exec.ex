defmodule CliSubprocessCore.Transport.SSHExec do
  @moduledoc false

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Transport
  alias CliSubprocessCore.Transport.{Error, RunResult, Subprocess}

  @behaviour Transport

  @ssh_surface_kinds [:static_ssh, :leased_ssh]

  @impl Transport
  def start(opts) when is_list(opts) do
    with {:ok, translated_opts} <- translate_transport_opts(opts) do
      Subprocess.start(translated_opts)
    end
  end

  @impl Transport
  def start_link(opts) when is_list(opts) do
    with {:ok, translated_opts} <- translate_transport_opts(opts) do
      Subprocess.start_link(translated_opts)
    end
  end

  @impl Transport
  def run(%Command{} = command, opts) when is_list(opts) do
    with {:ok, translated_command, original_command} <- translate_run_command(command, opts),
         {:ok, %RunResult{} = result} <- Subprocess.run(translated_command, opts) do
      {:ok, %RunResult{result | invocation: original_command}}
    else
      {:error, {:transport, %Error{} = error}} ->
        transport_error(restore_original_error(error, command))
    end
  end

  @impl Transport
  defdelegate send(transport, message), to: Subprocess

  @impl Transport
  defdelegate subscribe(transport, pid), to: Subprocess

  @impl Transport
  defdelegate subscribe(transport, pid, tag), to: Subprocess

  @impl Transport
  defdelegate unsubscribe(transport, pid), to: Subprocess

  @impl Transport
  defdelegate close(transport), to: Subprocess

  @impl Transport
  defdelegate force_close(transport), to: Subprocess

  @impl Transport
  defdelegate interrupt(transport), to: Subprocess

  @impl Transport
  defdelegate status(transport), to: Subprocess

  @impl Transport
  defdelegate end_input(transport), to: Subprocess

  @impl Transport
  defdelegate stderr(transport), to: Subprocess

  @impl Transport
  defdelegate info(transport), to: Subprocess

  defp translate_transport_opts(opts) do
    with {:ok, command} <- original_command(opts),
         {:ok, ssh_config} <- ssh_config(opts, command),
         remote_command <- remote_command(command),
         translated_command <- translated_command(ssh_config, remote_command) do
      {:ok,
       opts
       |> Keyword.put(:command, translated_command.command)
       |> Keyword.put(:args, translated_command.args)
       |> Keyword.put(:cwd, nil)
       |> Keyword.put(:env, %{})
       |> Keyword.put(:clear_env?, false)
       |> Keyword.put(:user, nil)
       |> Keyword.put(:invocation_override, command)
       |> Keyword.put(:adapter_metadata, adapter_metadata(ssh_config))}
    end
  end

  defp translate_run_command(%Command{} = command, opts) do
    with {:ok, ssh_config} <- ssh_config(opts, command),
         remote_command <- remote_command(command) do
      {:ok, translated_command(ssh_config, remote_command), command}
    end
  end

  defp original_command(opts) when is_list(opts) do
    case Keyword.get(opts, :command) do
      %Command{} = command ->
        {:ok, command}

      command when is_binary(command) ->
        {:ok,
         Command.new(command, Keyword.get(opts, :args, []),
           cwd: Keyword.get(opts, :cwd),
           env: Keyword.get(opts, :env, %{}),
           clear_env?: Keyword.get(opts, :clear_env?, false),
           user: Keyword.get(opts, :user)
         )}

      other ->
        transport_error(Error.invalid_options({:invalid_command, other}))
    end
  end

  defp ssh_config(opts, %Command{} = command) when is_list(opts) do
    surface_kind = Keyword.get(opts, :surface_kind, :local_subprocess)

    if surface_kind in @ssh_surface_kinds do
      with {:ok, transport_options} <- ssh_transport_options(opts),
           {:ok, destination} <-
             normalize_destination(Keyword.get(transport_options, :destination)),
           {:ok, ssh_path} <- normalize_ssh_path(Keyword.get(transport_options, :ssh_path)),
           {:ok, port} <- normalize_port(Keyword.get(transport_options, :port)),
           {:ok, ssh_user} <-
             normalize_optional_binary(
               Keyword.get(transport_options, :ssh_user) || command.user,
               :invalid_ssh_user
             ),
           {:ok, identity_file} <-
             normalize_optional_binary(
               Keyword.get(transport_options, :identity_file),
               :invalid_identity_file
             ),
           {:ok, ssh_args} <-
             normalize_binary_list(Keyword.get(transport_options, :ssh_args, [])),
           {:ok, ssh_options} <-
             normalize_ssh_options(Keyword.get(transport_options, :ssh_options, [])) do
        {:ok,
         %{
           destination: destination(ssh_user, destination),
           raw_destination: destination,
           ssh_path: ssh_path,
           port: port,
           ssh_user: ssh_user,
           identity_file: identity_file,
           ssh_args: ssh_args,
           ssh_options: ssh_options,
           pty?: Keyword.get(opts, :pty?, false)
         }}
      end
    else
      transport_error(Error.invalid_options({:invalid_surface_kind, surface_kind}))
    end
  end

  defp ssh_transport_options(opts) when is_list(opts) do
    case Keyword.fetch(opts, :transport_options) do
      {:ok, nested_options} ->
        normalize_transport_options(nested_options)

      :error ->
        {:ok,
         Keyword.take(opts, [
           :destination,
           :ssh_path,
           :port,
           :ssh_user,
           :identity_file,
           :ssh_args,
           :ssh_options
         ])}
    end
  end

  defp translated_command(ssh_config, remote_command) when is_map(ssh_config) do
    Command.new(ssh_config.ssh_path, ssh_argv(ssh_config, remote_command))
  end

  defp ssh_argv(ssh_config, remote_command) do
    []
    |> maybe_add_pair("-p", ssh_config.port)
    |> maybe_add_pair("-i", ssh_config.identity_file)
    |> maybe_add("-tt", ssh_config.pty?)
    |> Kernel.++(
      Enum.flat_map(ssh_config.ssh_options, fn {key, value} -> ["-o", "#{key}=#{value}"] end)
    )
    |> Kernel.++(ssh_config.ssh_args)
    |> Kernel.++([ssh_config.destination, remote_command])
  end

  defp remote_command(%Command{} = command) do
    exec_command =
      [
        command.command
        | command.args
      ]
      |> Enum.map_join(" ", &shell_escape/1)

    exec_command =
      case remote_env_command(command.env, command.clear_env?) do
        nil -> exec_command
        env_command -> "#{env_command} #{exec_command}"
      end

    exec_command = "exec #{exec_command}"

    case command.cwd do
      cwd when is_binary(cwd) and cwd != "" ->
        "cd #{shell_escape(cwd)} && #{exec_command}"

      _ ->
        exec_command
    end
  end

  defp remote_env_command(env, clear_env?) when env == %{} and clear_env? == false, do: nil

  defp remote_env_command(env, clear_env?) when is_map(env) do
    assignments =
      env
      |> Enum.map_join(" ", fn {key, value} ->
        "#{shell_env_key(key)}=#{shell_escape(value)}"
      end)

    cond do
      clear_env? and assignments == "" -> "env -i"
      clear_env? -> "env -i #{assignments}"
      assignments == "" -> nil
      true -> "env #{assignments}"
    end
  end

  defp adapter_metadata(ssh_config) do
    %{
      destination: ssh_config.raw_destination,
      port: ssh_config.port,
      ssh_path: ssh_config.ssh_path,
      ssh_user: ssh_config.ssh_user,
      identity_file: ssh_config.identity_file,
      ssh_options: Map.new(ssh_config.ssh_options),
      ssh_args: ssh_config.ssh_args
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] or value == %{} end)
    |> Map.new()
  end

  defp normalize_transport_options(nil), do: {:ok, []}

  defp normalize_transport_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      {:ok, options}
    else
      transport_error(Error.invalid_options({:invalid_transport_options, options}))
    end
  end

  defp normalize_transport_options(options) when is_map(options) do
    if Enum.all?(Map.keys(options), &is_atom/1) do
      {:ok, Enum.into(options, [])}
    else
      transport_error(Error.invalid_options({:invalid_transport_options, options}))
    end
  end

  defp normalize_transport_options(options),
    do: transport_error(Error.invalid_options({:invalid_transport_options, options}))

  defp normalize_destination(nil),
    do: transport_error(Error.invalid_options({:missing_ssh_destination, nil}))

  defp normalize_destination(destination) when is_binary(destination) and destination != "",
    do: {:ok, destination}

  defp normalize_destination(destination),
    do: transport_error(Error.invalid_options({:invalid_ssh_destination, destination}))

  defp normalize_ssh_path(nil), do: {:ok, System.find_executable("ssh") || "ssh"}

  defp normalize_ssh_path(path) when is_binary(path) and path != "",
    do: {:ok, path}

  defp normalize_ssh_path(path),
    do: transport_error(Error.invalid_options({:invalid_ssh_path, path}))

  defp normalize_port(nil), do: {:ok, nil}
  defp normalize_port(port) when is_integer(port) and port > 0, do: {:ok, port}
  defp normalize_port(port), do: transport_error(Error.invalid_options({:invalid_ssh_port, port}))

  defp normalize_optional_binary(nil, _reason), do: {:ok, nil}

  defp normalize_optional_binary(value, _reason) when is_binary(value) and value != "",
    do: {:ok, value}

  defp normalize_optional_binary(value, reason),
    do: transport_error(Error.invalid_options({reason, value}))

  defp normalize_binary_list(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      {:ok, values}
    else
      transport_error(Error.invalid_options({:invalid_ssh_args, values}))
    end
  end

  defp normalize_binary_list(values),
    do: transport_error(Error.invalid_options({:invalid_ssh_args, values}))

  defp normalize_ssh_options(nil), do: {:ok, []}

  defp normalize_ssh_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      {:ok, Enum.map(options, fn {key, value} -> {to_string(key), ssh_option_value(value)} end)}
    else
      transport_error(Error.invalid_options({:invalid_ssh_options, options}))
    end
  end

  defp normalize_ssh_options(options) when is_map(options) do
    if Enum.all?(Map.keys(options), &(is_atom(&1) or is_binary(&1))) do
      {:ok,
       options
       |> Enum.map(fn {key, value} -> {to_string(key), ssh_option_value(value)} end)
       |> Enum.sort()}
    else
      transport_error(Error.invalid_options({:invalid_ssh_options, options}))
    end
  end

  defp normalize_ssh_options(options),
    do: transport_error(Error.invalid_options({:invalid_ssh_options, options}))

  defp ssh_option_value(true), do: "yes"
  defp ssh_option_value(false), do: "no"
  defp ssh_option_value(value) when is_binary(value), do: value
  defp ssh_option_value(value) when is_integer(value), do: Integer.to_string(value)
  defp ssh_option_value(value) when is_atom(value), do: Atom.to_string(value)
  defp ssh_option_value(value), do: to_string(value)

  defp destination(nil, destination), do: destination
  defp destination(user, destination), do: "#{user}@#{destination}"

  defp maybe_add(list, _value, false), do: list
  defp maybe_add(list, value, true), do: list ++ [value]

  defp maybe_add_pair(list, _flag, nil), do: list
  defp maybe_add_pair(list, flag, value), do: list ++ [flag, to_string(value)]

  defp shell_env_key(key) do
    key
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_]/, "_")
  end

  defp shell_escape(value) when is_binary(value) do
    escaped = String.replace(value, "'", "'\"'\"'")
    "'#{escaped}'"
  end

  defp restore_original_error(%Error{} = error, %Command{} = command) do
    context =
      error.context
      |> Map.put(:command, command.command)
      |> Map.put(:args, command.args)

    %Error{error | context: context}
  end

  defp transport_error(%Error{} = error), do: {:error, {:transport, error}}
end
