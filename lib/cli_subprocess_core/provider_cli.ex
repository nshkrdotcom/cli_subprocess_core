defmodule CliSubprocessCore.ProviderCLI do
  @moduledoc """
  Shared provider-specific CLI resolution policies for the core runtime.

  Built-in provider profiles should resolve their launch program through this
  module instead of duplicating discovery logic in downstream adapters.
  """

  alias CliSubprocessCore.CommandSpec

  defmodule Error do
    @moduledoc """
    Exception returned when provider CLI resolution fails.
    """

    @enforce_keys [:kind, :provider, :message]
    defexception [:kind, :provider, :message, :cause]

    @type t :: %__MODULE__{
            kind: :cli_not_found | :unsupported_provider,
            provider: atom(),
            message: String.t(),
            cause: term()
          }

    @impl true
    def message(%__MODULE__{message: message}), do: message
  end

  @type resolve_opt ::
          {:default_command, String.t()}
          | {:display_name, String.t()}
          | {:env_var, String.t() | nil}
          | {:extra_keys, [atom()]}
          | {:install_hint, String.t() | nil}
          | {:npm_global_bin, String.t() | nil}
          | {:npx_command, String.t() | nil}
          | {:npx_disable_env, String.t() | nil}
          | {:npx_package, String.t() | nil}
          | {:resolution_cwd, String.t() | nil}

  @provider_settings %{
    amp: %{
      default_command: "amp",
      display_name: "Amp CLI",
      env_var: "AMP_CLI_PATH",
      install_hint: "npm install -g @sourcegraph/amp",
      npm_global_bin: nil,
      npx_command: nil,
      npx_disable_env: nil,
      npx_package: nil
    },
    claude: %{
      default_command: "claude",
      display_name: "Claude CLI",
      env_var: "CLAUDE_CLI_PATH",
      install_hint: "npm install -g @anthropic-ai/claude-code",
      npm_global_bin: nil,
      npx_command: nil,
      npx_disable_env: nil,
      npx_package: nil
    },
    codex: %{
      default_command: "codex",
      display_name: "Codex CLI",
      env_var: "CODEX_PATH",
      install_hint: "npm install -g @openai/codex",
      npm_global_bin: nil,
      npx_command: nil,
      npx_disable_env: nil,
      npx_package: nil
    },
    gemini: %{
      default_command: "gemini",
      display_name: "Gemini CLI",
      env_var: "GEMINI_CLI_PATH",
      install_hint: "npm install -g @google/gemini-cli",
      npm_global_bin: "gemini",
      npx_command: "gemini",
      npx_disable_env: "GEMINI_NO_NPX",
      npx_package: "@google/gemini-cli"
    }
  }
  @env_launchers ["/usr/bin/env", "/bin/env", "env"]

  @spec resolve(atom(), keyword(), [resolve_opt()]) ::
          {:ok, CommandSpec.t()} | {:error, Error.t()}
  def resolve(provider, provider_opts \\ [], opts \\ [])
      when is_atom(provider) and is_list(provider_opts) and is_list(opts) do
    with {:ok, settings} <- build_settings(provider, opts),
         {:ok, spec} <- resolve_spec(provider_opts, settings) do
      maybe_stabilize_command_spec(spec, settings)
    end
  end

  @spec resolve!(atom(), keyword(), [resolve_opt()]) :: CommandSpec.t()
  def resolve!(provider, provider_opts \\ [], opts \\ []) do
    case resolve(provider, provider_opts, opts) do
      {:ok, %CommandSpec{} = spec} ->
        spec

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp build_settings(provider, opts) do
    base_settings = Map.get(@provider_settings, provider, %{})

    settings =
      base_settings
      |> Map.merge(Map.new(opts))
      |> Map.put_new(:extra_keys, [])
      |> Map.put_new_lazy(:resolution_cwd, &File.cwd!/0)
      |> Map.put(:provider, provider)

    case Map.get(settings, :default_command) do
      value when is_binary(value) and value != "" ->
        {:ok, settings}

      _other ->
        {:error,
         %Error{
           kind: :unsupported_provider,
           provider: provider,
           message: "unsupported provider #{inspect(provider)} for CLI resolution"
         }}
    end
  end

  defp resolve_spec(provider_opts, settings) do
    with :miss <- explicit_override(provider_opts, settings),
         :miss <- env_override(settings),
         :miss <- path_lookup(settings.default_command),
         :miss <- npm_global_lookup(settings),
         :miss <- npx_lookup(settings) do
      {:error, cli_not_found(settings.provider, settings)}
    end
  end

  defp explicit_override(provider_opts, settings) do
    keys = [:command_spec, :command, :executable] ++ Map.get(settings, :extra_keys, [])

    Enum.find_value(keys, :miss, fn
      :command_spec ->
        case Keyword.get(provider_opts, :command_spec) do
          %CommandSpec{} = spec ->
            {:ok, spec}

          _other ->
            false
        end

      key ->
        case Keyword.get(provider_opts, key) do
          value when is_binary(value) and value != "" ->
            explicit_string_override(value, settings)

          _other ->
            false
        end
    end)
  end

  defp explicit_string_override(value, _settings) when is_binary(value) do
    case explicit_path(value) do
      {:ok, %CommandSpec{} = spec} -> {:ok, spec}
      :miss -> {:ok, CommandSpec.new(value)}
      {:error, _reason} = error -> error
    end
  end

  defp env_override(%{env_var: env_var} = settings) when is_binary(env_var) and env_var != "" do
    case System.get_env(env_var) do
      nil ->
        :miss

      "" ->
        :miss

      value ->
        case env_string_override(value, settings) do
          {:ok, %CommandSpec{} = spec} ->
            {:ok, spec}

          {:error, reason} ->
            {:error,
             %Error{
               kind: :cli_not_found,
               provider: settings.provider,
               message: reason_message(env_var, value, reason),
               cause: reason
             }}
        end
    end
  end

  defp env_override(_settings), do: :miss

  defp env_string_override(value, _settings) when is_binary(value) do
    case explicit_path(value) do
      {:ok, %CommandSpec{} = spec} ->
        {:ok, spec}

      :miss ->
        case System.find_executable(value) do
          nil -> {:error, :missing}
          path -> {:ok, CommandSpec.new(path)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp path_lookup(command) when is_binary(command) and command != "" do
    case System.find_executable(command) do
      nil -> :miss
      path -> {:ok, CommandSpec.new(path)}
    end
  end

  defp path_lookup(_command), do: :miss

  defp npm_global_lookup(%{npm_global_bin: nil}), do: :miss

  defp npm_global_lookup(%{npm_global_bin: binary}) when is_binary(binary) do
    with {:ok, npm_path} <- find_npm(),
         {:ok, prefix} <- npm_global_prefix(npm_path) do
      candidate = Path.join([prefix, "bin", binary])

      case explicit_path(candidate) do
        {:ok, %CommandSpec{} = spec} -> {:ok, spec}
        _other -> :miss
      end
    else
      _ -> :miss
    end
  end

  defp npx_lookup(%{npx_package: nil}), do: :miss

  defp npx_lookup(%{
         npx_package: package,
         npx_command: command,
         npx_disable_env: disable_env
       })
       when is_binary(package) and is_binary(command) do
    if npx_disabled?(disable_env) do
      :miss
    else
      case System.find_executable("npx") do
        nil ->
          :miss

        npx_path ->
          {:ok,
           CommandSpec.new(npx_path,
             argv_prefix: ["--yes", "--package", package, command]
           )}
      end
    end
  end

  defp explicit_path(value) when is_binary(value) do
    if path_like?(value) do
      cond do
        not File.exists?(value) ->
          {:error, :missing}

        not executable?(value) ->
          {:error, :not_executable}

        true ->
          {:ok, CommandSpec.new(value)}
      end
    else
      :miss
    end
  end

  defp find_npm do
    case System.find_executable("npm") do
      nil -> :miss
      path -> {:ok, path}
    end
  end

  defp npm_global_prefix(npm_path) do
    case System.cmd(npm_path, ["prefix", "-g"], stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "" -> :miss
          prefix -> {:ok, prefix}
        end

      _other ->
        :miss
    end
  rescue
    _error -> :miss
  end

  defp npx_disabled?(disable_env) when is_binary(disable_env) and disable_env != "" do
    System.get_env(disable_env) in ["1", "true"]
  end

  defp npx_disabled?(_other), do: false

  defp maybe_stabilize_command_spec(
         %CommandSpec{program: program, argv_prefix: []} = spec,
         settings
       )
       when is_binary(program) do
    if path_like?(program) and File.exists?(program) do
      case stabilize_entrypoint(spec, settings) do
        {:ok, %CommandSpec{} = stabilized_spec} ->
          {:ok, stabilized_spec}

        {:error, {:program_shim_resolution_failed, path, reason}} ->
          {:error, shim_resolution_error(settings, path, reason)}

        {:error, {:shebang_resolution_failed, script_path, reason}} ->
          {:error, shebang_resolution_error(settings, script_path, reason)}
      end
    else
      {:ok, spec}
    end
  end

  defp maybe_stabilize_command_spec(%CommandSpec{} = spec, _settings), do: {:ok, spec}

  defp stabilize_entrypoint(%CommandSpec{program: program} = spec, settings) do
    with {:ok, stabilized_program} <- stabilize_top_level_program(program, settings),
         {:ok, maybe_wrapped_spec} <-
           maybe_promote_shebang_command(stabilized_program, settings) do
      case maybe_wrapped_spec do
        nil ->
          {:ok, %CommandSpec{spec | program: stabilized_program}}

        %CommandSpec{} = wrapped_spec ->
          {:ok, wrapped_spec}
      end
    end
  end

  defp stabilize_top_level_program(program, settings) do
    case stabilize_program(program, settings) do
      :unchanged ->
        {:ok, program}

      {:ok, stabilized_program} ->
        {:ok, stabilized_program}

      {:error, reason} ->
        {:error, {:program_shim_resolution_failed, program, reason}}
    end
  end

  defp maybe_promote_shebang_command(script_path, settings) when is_binary(script_path) do
    case shebang_command(script_path) do
      :none ->
        {:ok, nil}

      {:ok, {command, command_prefix}} ->
        case maybe_wrap_shebang_command(command, command_prefix, script_path, settings) do
          {:ok, nil} ->
            {:ok, nil}

          {:ok, %CommandSpec{} = spec} ->
            {:ok, spec}

          {:error, reason} ->
            {:error, {:shebang_resolution_failed, script_path, reason}}
        end
    end
  end

  defp maybe_wrap_shebang_command(command, command_prefix, script_path, settings)
       when is_binary(command) and is_list(command_prefix) and is_binary(script_path) do
    case resolve_command_path(command) do
      {:ok, interpreter_path} ->
        case stabilize_program(interpreter_path, settings) do
          :unchanged ->
            {:ok, nil}

          {:ok, stabilized_interpreter} ->
            {:ok,
             CommandSpec.new(stabilized_interpreter, argv_prefix: command_prefix ++ [script_path])}

          {:error, reason} ->
            {:error, {:interpreter_shim_resolution_failed, interpreter_path, reason}}
        end

      :miss ->
        {:ok, nil}
    end
  end

  defp resolve_command_path(command) when is_binary(command) do
    case explicit_path(command) do
      {:ok, %CommandSpec{program: program}} ->
        {:ok, program}

      :miss ->
        case System.find_executable(command) do
          nil -> :miss
          path -> {:ok, path}
        end

      {:error, _reason} ->
        :miss
    end
  end

  defp shebang_command(path) when is_binary(path) do
    case read_first_line(path) do
      {:ok, <<"#!", remainder::binary>>} ->
        parse_shebang(remainder)

      _other ->
        :none
    end
  end

  defp read_first_line(path) when is_binary(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          case IO.binread(device, :line) do
            :eof -> :eof
            line when is_binary(line) -> {:ok, line}
          end
        after
          File.close(device)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_shebang(remainder) when is_binary(remainder) do
    remainder
    |> String.trim()
    |> shebang_argv()
  rescue
    _error -> :none
  end

  defp shebang_argv(""), do: :none

  defp shebang_argv(line) when is_binary(line) do
    case OptionParser.split(line) do
      [] ->
        :none

      [launcher | rest] when launcher in @env_launchers ->
        case env_command(rest) do
          {:ok, command, command_prefix} ->
            {:ok, {command, command_prefix}}

          _ ->
            :none
        end

      [command | command_prefix] ->
        {:ok, {command, command_prefix}}
    end
  end

  defp env_command(args) when is_list(args) do
    do_env_command(args)
  end

  defp do_env_command([]), do: :error

  defp do_env_command(["-S" | rest]) do
    case rest do
      [command | command_prefix] -> {:ok, command, command_prefix}
      [] -> :error
    end
  end

  defp do_env_command(["--" | rest]), do: do_env_command(rest)
  defp do_env_command(["-" | rest]), do: do_env_command(rest)
  defp do_env_command(["-i" | rest]), do: do_env_command(rest)
  defp do_env_command(["--ignore-environment" | rest]), do: do_env_command(rest)
  defp do_env_command(["-u", _var | rest]), do: do_env_command(rest)
  defp do_env_command(["-u"]), do: :error

  defp do_env_command([<<"-u", _::binary>> | rest]), do: do_env_command(rest)

  defp do_env_command([assignment | rest]) do
    if env_assignment?(assignment) do
      do_env_command(rest)
    else
      do_env_command_non_assignment([assignment | rest])
    end
  end

  defp do_env_command_non_assignment([<<"-", _::binary>> | _rest]), do: :error

  defp do_env_command_non_assignment([command | command_prefix]),
    do: {:ok, command, command_prefix}

  defp env_assignment?(value) when is_binary(value) do
    case String.split(value, "=", parts: 2) do
      [key, _] -> key != "" and not String.starts_with?(key, "-")
      _other -> false
    end
  end

  defp stabilize_program(program, settings) do
    case version_manager_shim(program) do
      nil ->
        :unchanged

      manager ->
        resolve_shim_target(manager, program, settings)
    end
  end

  defp resolve_shim_target(manager, shim_path, settings) do
    command = Path.basename(shim_path)

    with {:ok, manager_executable} <- version_manager_executable(manager, shim_path),
         {:ok, resolved_path} <-
           run_version_manager_which(manager, manager_executable, command, settings),
         true <-
           File.exists?(resolved_path) || {:error, {:resolved_target_missing, resolved_path}},
         true <-
           executable?(resolved_path) ||
             {:error, {:resolved_target_not_executable, resolved_path}} do
      {:ok, resolved_path}
    else
      {:error, _reason} = error ->
        error

      false ->
        {:error, :shim_resolution_failed}
    end
  end

  defp version_manager_shim(path) when is_binary(path) do
    expanded = Path.expand(path)

    cond do
      String.contains?(expanded, "/.asdf/shims/") or file_contains?(expanded, "asdf exec") ->
        :asdf

      String.contains?(expanded, "/.local/share/mise/shims/") or
        String.contains?(expanded, "/.mise/shims/") or file_contains?(expanded, "mise exec") ->
        :mise

      String.contains?(expanded, "/.rtx/shims/") or file_contains?(expanded, "rtx exec") ->
        :rtx

      true ->
        nil
    end
  end

  defp version_manager_executable(:asdf, shim_path) do
    shim_root = shim_path |> Path.expand() |> Path.dirname() |> Path.dirname()

    [
      System.get_env("ASDF_BIN"),
      Path.join(shim_root, "bin/asdf"),
      asdf_dir_candidate(),
      System.find_executable("asdf")
    ]
    |> first_executable()
  end

  defp version_manager_executable(:mise, _shim_path) do
    [
      System.get_env("MISE_BIN"),
      System.find_executable("mise"),
      Path.join(System.user_home!(), ".local/bin/mise")
    ]
    |> first_executable()
  end

  defp version_manager_executable(:rtx, _shim_path) do
    [
      System.find_executable("rtx"),
      Path.join(System.user_home!(), ".local/bin/rtx")
    ]
    |> first_executable()
  end

  defp run_version_manager_which(manager, executable, command, settings)
       when is_binary(executable) and is_binary(command) do
    opts =
      [stderr_to_stdout: true]
      |> maybe_put_cd(Map.get(settings, :resolution_cwd))

    case System.cmd(executable, ["which", command], opts) do
      {output, 0} ->
        case String.trim(output) do
          "" -> {:error, :empty_which_output}
          resolved_path -> {:ok, resolved_path}
        end

      {output, status} ->
        {:error, {:which_failed, manager, status, String.trim(output)}}
    end
  rescue
    error ->
      {:error, {:which_raised, manager, error}}
  end

  defp first_executable(paths) when is_list(paths) do
    paths
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.find_value({:error, :manager_not_found}, fn path ->
      if executable?(path), do: {:ok, path}, else: false
    end)
  end

  defp maybe_put_cd(opts, cwd) when is_binary(cwd) and cwd != "", do: Keyword.put(opts, :cd, cwd)
  defp maybe_put_cd(opts, _cwd), do: opts

  defp asdf_dir_candidate do
    case System.get_env("ASDF_DIR") do
      value when is_binary(value) and value != "" ->
        Path.join(value, "bin/asdf")

      _ ->
        Path.join(System.user_home!(), ".asdf/bin/asdf")
    end
  end

  defp file_contains?(path, marker) when is_binary(path) and is_binary(marker) do
    case File.read(path) do
      {:ok, contents} -> String.contains?(contents, marker)
      _ -> false
    end
  end

  defp shim_resolution_error(settings, path, reason) do
    display_name = Map.get(settings, :display_name, "#{settings.provider} CLI")
    cwd = Map.get(settings, :resolution_cwd)

    message =
      "#{display_name} resolved to a version-manager shim at #{inspect(path)}" <>
        resolution_cwd_suffix(cwd) <>
        " but could not be resolved to a stable executable: #{format_shim_reason(reason)}"

    %Error{
      kind: :cli_not_found,
      provider: settings.provider,
      message: message,
      cause: reason
    }
  end

  defp shebang_resolution_error(
         settings,
         script_path,
         {:interpreter_shim_resolution_failed, path, reason}
       ) do
    display_name = Map.get(settings, :display_name, "#{settings.provider} CLI")

    message =
      "#{display_name} launcher at #{inspect(script_path)} depends on an interpreter that " <>
        "could not be resolved to a stable executable: " <>
        "interpreter shim #{inspect(path)} could not be resolved: #{format_shim_reason(reason)}"

    %Error{
      kind: :cli_not_found,
      provider: settings.provider,
      message: message,
      cause: reason
    }
  end

  defp resolution_cwd_suffix(cwd) when is_binary(cwd) and cwd != "", do: " from #{inspect(cwd)}"
  defp resolution_cwd_suffix(_cwd), do: ""

  defp format_shim_reason({:which_failed, _manager, status, output}) do
    "version manager lookup exited with status #{status}" <> format_output_suffix(output)
  end

  defp format_shim_reason({:which_raised, _manager, error}) do
    "version manager lookup raised #{Exception.message(error)}"
  rescue
    _ -> "version manager lookup raised #{inspect(error)}"
  end

  defp format_shim_reason({:resolved_target_missing, path}),
    do: "resolved target does not exist: #{inspect(path)}"

  defp format_shim_reason({:resolved_target_not_executable, path}),
    do: "resolved target is not executable: #{inspect(path)}"

  defp format_shim_reason(:manager_not_found),
    do: "the version manager executable could not be located"

  defp format_shim_reason(:empty_which_output), do: "the version manager returned an empty path"

  defp format_shim_reason(:shim_resolution_failed),
    do: "shim resolution did not return a usable executable"

  defp format_shim_reason(other), do: inspect(other)

  defp format_output_suffix(""), do: ""
  defp format_output_suffix(output), do: ": #{output}"

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp path_like?(value) do
    String.starts_with?(value, "/") or String.starts_with?(value, ".") or
      String.contains?(value, "/")
  end

  defp cli_not_found(provider, settings) do
    display_name = Map.get(settings, :display_name, "#{provider} CLI")
    install_hint = Map.get(settings, :install_hint)
    npx_package = Map.get(settings, :npx_package)

    message =
      case {install_hint, npx_package} do
        {hint, package} when is_binary(hint) and is_binary(package) ->
          "#{display_name} not found. Install with: #{hint} — or ensure npx is available for automatic resolution."

        {hint, _package} when is_binary(hint) ->
          "#{display_name} not found. Install with: #{hint}"

        _other ->
          "#{display_name} not found."
      end

    %Error{
      kind: :cli_not_found,
      provider: provider,
      message: message
    }
  end

  defp reason_message(env_var, value, :missing),
    do: "#{env_var} points to non-existent file: #{value}"

  defp reason_message(env_var, value, :not_executable),
    do: "#{env_var} points to non-executable file: #{value}"
end
