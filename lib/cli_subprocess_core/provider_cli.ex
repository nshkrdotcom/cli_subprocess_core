defmodule CliSubprocessCore.ProviderCLI do
  @moduledoc """
  Shared provider-specific CLI resolution policies for the core runtime.

  Built-in provider profiles should resolve their launch program through this
  module instead of duplicating discovery logic in downstream adapters.
  """

  alias CliSubprocessCore.{CommandSpec, ExecutionSurface}
  alias ExecutionPlane.Process.Transport.Error, as: TransportError
  alias ExecutionPlane.ProcessExit

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

  defmodule ErrorRuntimeFailure do
    @moduledoc """
    Structured provider CLI runtime failure.

    This is used after a provider command has already been selected and a
    process was started, but the runtime still failed due to missing
    executables, invalid working-directory placement, authentication problems,
    or a generic process/transport failure.
    """

    @enforce_keys [:kind, :provider, :message]
    defexception [:kind, :provider, :message, :exit_code, :stderr, :context, :cause]

    @type kind ::
            :auth_error
            | :cli_not_found
            | :cwd_not_found
            | :process_exit
            | :transport_error

    @type t :: %__MODULE__{
            kind: kind(),
            provider: atom(),
            message: String.t(),
            exit_code: integer() | nil,
            stderr: String.t() | nil,
            context: map(),
            cause: term()
          }

    @impl true
    def message(%__MODULE__{message: message}), do: message
  end

  @type resolve_opt ::
          {:allow_js_entrypoint, boolean()}
          | {:default_command, String.t()}
          | {:display_name, String.t()}
          | {:env_var, String.t() | nil}
          | {:execution_surface, ExecutionSurface.t() | map() | keyword() | nil}
          | {:extra_keys, [atom()]}
          | {:install_hint, String.t() | nil}
          | {:known_locations, [String.t()]}
          | {:known_locations_first?, boolean()}
          | {:node_command, String.t()}
          | {:npm_global_bin, String.t() | nil}
          | {:npx_command, String.t() | nil}
          | {:npx_disable_env, String.t() | nil}
          | {:npx_package, String.t() | nil}
          | {:path_candidates, [String.t()]}
          | {:resolution_cwd, String.t() | nil}

  @type runtime_failure_opt ::
          {:command, String.t() | nil}
          | {:cwd, String.t() | nil}
          | {:execution_surface, ExecutionSurface.t() | map() | keyword() | nil}
          | {:stderr, String.t() | nil}

  @provider_settings %{
    amp: %{
      default_command: "amp",
      display_name: "Amp CLI",
      env_var: "AMP_CLI_PATH",
      install_hint: "npm install -g @sourcegraph/amp",
      allow_js_entrypoint: true,
      known_locations_first?: true,
      node_command: "node",
      npm_global_bin: nil,
      npx_command: nil,
      npx_disable_env: nil,
      npx_package: nil,
      path_candidates: ["amp"]
    },
    claude: %{
      default_command: "claude-code",
      remote_default_command: "claude",
      display_name: "Claude CLI",
      env_var: "CLAUDE_CLI_PATH",
      install_hint: "npm install -g @anthropic-ai/claude-code",
      allow_js_entrypoint: false,
      node_command: "node",
      npm_global_bin: nil,
      npx_command: nil,
      npx_disable_env: nil,
      npx_package: nil,
      path_candidates: ["claude-code", "claude"]
    },
    codex: %{
      default_command: "codex",
      display_name: "Codex CLI",
      env_var: "CODEX_PATH",
      install_hint: "npm install -g @openai/codex",
      allow_js_entrypoint: false,
      node_command: "node",
      npm_global_bin: nil,
      npx_command: nil,
      npx_disable_env: nil,
      npx_package: nil,
      path_candidates: ["codex"]
    },
    gemini: %{
      default_command: "gemini",
      display_name: "Gemini CLI",
      env_var: "GEMINI_CLI_PATH",
      install_hint: "npm install -g @google/gemini-cli",
      allow_js_entrypoint: false,
      node_command: "node",
      npm_global_bin: "gemini",
      npx_command: "gemini",
      npx_disable_env: "GEMINI_NO_NPX",
      npx_package: "@google/gemini-cli",
      path_candidates: ["gemini"]
    }
  }
  @env_launchers ["/usr/bin/env", "/bin/env", "env"]

  @spec resolve(atom(), keyword(), [resolve_opt()]) ::
          {:ok, CommandSpec.t()} | {:error, Error.t()}
  def resolve(provider, provider_opts \\ [], opts \\ [])
      when is_atom(provider) and is_list(provider_opts) and is_list(opts) do
    with {:ok, settings} <- build_settings(provider, opts),
         settings = Map.put(settings, :resolution_mode, resolution_mode(provider_opts, settings)),
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

  @doc """
  Classifies a provider runtime failure after launch selection has already
  completed.

  This covers both local transport errors (for example `{:command_not_found,
  "gemini"}`) and remote execution failures that only become visible after the
  provider command is invoked over an execution surface such as SSH.
  """
  @spec runtime_failure(atom(), term(), [runtime_failure_opt()]) :: ErrorRuntimeFailure.t()
  def runtime_failure(provider, reason, opts \\ [])
      when is_atom(provider) and is_list(opts) do
    settings =
      case build_settings(provider, []) do
        {:ok, settings} -> settings
        {:error, _reason} -> fallback_settings(provider)
      end

    context = runtime_failure_context(settings, opts)

    case unwrap_runtime_reason(reason) do
      %ErrorRuntimeFailure{} = failure ->
        failure

      %TransportError{} = error ->
        transport_runtime_failure(settings, error, context)

      %ProcessExit{} = exit ->
        process_exit_runtime_failure(settings, exit, context)

      other ->
        generic_runtime_failure(settings, other, context)
    end
  end

  @doc """
  Maps a classified runtime failure to the stable public error code used across
  the shared provider/runtime stack.
  """
  @spec runtime_failure_code(ErrorRuntimeFailure.t()) :: String.t()
  def runtime_failure_code(%ErrorRuntimeFailure{kind: :auth_error}), do: "auth_error"
  def runtime_failure_code(%ErrorRuntimeFailure{kind: :cli_not_found}), do: "cli_not_found"
  def runtime_failure_code(%ErrorRuntimeFailure{kind: :cwd_not_found}), do: "config_invalid"
  def runtime_failure_code(%ErrorRuntimeFailure{kind: :process_exit}), do: "transport_exit"
  def runtime_failure_code(%ErrorRuntimeFailure{kind: :transport_error}), do: "transport_error"

  defp build_settings(provider, opts) do
    base_settings = Map.get(@provider_settings, provider, %{})

    settings =
      base_settings
      |> Map.merge(Map.new(opts))
      |> Map.put_new(:extra_keys, [])
      |> Map.put_new_lazy(:path_candidates, fn -> [Map.get(base_settings, :default_command)] end)
      |> Map.put_new_lazy(:known_locations, fn -> default_known_locations(provider) end)
      |> Map.put_new(:known_locations_first?, false)
      |> Map.put_new(:allow_js_entrypoint, false)
      |> Map.put_new_lazy(:remote_default_command, fn ->
        Map.get(base_settings, :default_command)
      end)
      |> Map.put_new(:node_command, "node")
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

  defp fallback_settings(provider) do
    base_settings = Map.get(@provider_settings, provider, %{})

    %{
      provider: provider,
      default_command: Map.get(base_settings, :default_command, Atom.to_string(provider)),
      display_name: Map.get(base_settings, :display_name, "#{provider} CLI"),
      install_hint: Map.get(base_settings, :install_hint),
      path_candidates: Map.get(base_settings, :path_candidates, [Atom.to_string(provider)])
    }
  end

  defp resolve_spec(provider_opts, settings) do
    if nonlocal_path_resolution?(settings) do
      with :miss <- explicit_override(provider_opts, settings) do
        {:ok, CommandSpec.new(remote_default_command(settings))}
      end
    else
      path_steps =
        if Map.get(settings, :known_locations_first?, false) do
          [&known_location_lookup/1, &path_lookup/1]
        else
          [&path_lookup/1, &known_location_lookup/1]
        end

      with :miss <- explicit_override(provider_opts, settings),
           :miss <- env_override(settings),
           :miss <- run_lookup_steps(path_steps, settings),
           :miss <- npm_global_lookup(settings),
           :miss <- npx_lookup(settings) do
        {:error, cli_not_found(settings.provider, settings)}
      end
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

  defp explicit_string_override(value, settings) when is_binary(value) do
    if nonlocal_path_resolution?(settings) do
      {:ok, CommandSpec.new(value)}
    else
      case explicit_path(value, settings) do
        {:ok, %CommandSpec{} = spec} -> {:ok, spec}
        :miss -> {:ok, CommandSpec.new(value)}
        {:error, _reason} = error -> error
      end
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

  defp env_string_override(value, settings) when is_binary(value) do
    case explicit_path(value, settings) do
      {:ok, %CommandSpec{} = spec} ->
        {:ok, spec}

      :miss ->
        case find_executable_candidate(value, settings) do
          nil -> {:error, :missing}
          path -> explicit_path(path, settings)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp path_lookup(%{path_candidates: candidates} = settings) when is_list(candidates) do
    Enum.find_value(candidates, :miss, fn
      candidate when is_binary(candidate) and candidate != "" ->
        case find_executable_candidate(candidate, settings) do
          nil -> false
          path -> explicit_path(path, settings)
        end

      _other ->
        false
    end)
  end

  defp path_lookup(_settings), do: :miss

  defp known_location_lookup(%{known_locations: locations} = settings) when is_list(locations) do
    Enum.find_value(locations, :miss, fn
      path when is_binary(path) and path != "" ->
        case explicit_path(path, settings) do
          {:ok, %CommandSpec{} = spec} -> {:ok, spec}
          _other -> false
        end

      _other ->
        false
    end)
  end

  defp known_location_lookup(_settings), do: :miss

  defp npm_global_lookup(%{npm_global_bin: nil}), do: :miss

  defp npm_global_lookup(%{npm_global_bin: binary} = settings) when is_binary(binary) do
    with {:ok, npm_path} <- find_npm(),
         {:ok, prefix} <- npm_global_prefix(npm_path) do
      candidate = Path.join([prefix, "bin", binary])

      case explicit_path(candidate, settings) do
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

  defp explicit_path(value, settings) when is_binary(value) do
    if path_like?(value) do
      cond do
        js_entrypoint?(value, settings) and not File.regular?(value) ->
          {:error, :missing}

        js_entrypoint?(value, settings) ->
          wrap_js_entrypoint(value, settings)

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
    cond do
      nonlocal_path_resolution?(settings) ->
        {:ok, spec}

      path_like?(program) and File.exists?(program) ->
        case stabilize_entrypoint(spec, settings) do
          {:ok, %CommandSpec{} = stabilized_spec} ->
            {:ok, stabilized_spec}

          {:error, {:program_shim_resolution_failed, path, reason}} ->
            {:error, shim_resolution_error(settings, path, reason)}

          {:error, {:shebang_resolution_failed, script_path, reason}} ->
            {:error, shebang_resolution_error(settings, script_path, reason)}
        end

      true ->
        {:ok, spec}
    end
  end

  defp maybe_stabilize_command_spec(%CommandSpec{} = spec, _settings), do: {:ok, spec}

  defp resolution_mode(provider_opts, settings) do
    cond do
      Map.get(settings, :resolution_mode) in [:local_path, :nonlocal_path] ->
        Map.fetch!(settings, :resolution_mode)

      Map.get(settings, :resolution_mode) in [:local, :remote] ->
        legacy_resolution_mode(Map.fetch!(settings, :resolution_mode))

      ExecutionSurface.nonlocal_path_surface?(Keyword.get(provider_opts, :execution_surface)) ->
        :nonlocal_path

      ExecutionSurface.nonlocal_path_surface?(Map.get(settings, :execution_surface)) ->
        :nonlocal_path

      ExecutionSurface.nonlocal_path_surface?(
        surface_context(
          Keyword.get(provider_opts, :surface_kind),
          Keyword.get(provider_opts, :transport_options)
        )
      ) ->
        :nonlocal_path

      ExecutionSurface.nonlocal_path_surface?(
        surface_context(Map.get(settings, :surface_kind), Map.get(settings, :transport_options))
      ) ->
        :nonlocal_path

      true ->
        :local_path
    end
  end

  defp surface_context(nil, _transport_options), do: nil

  defp surface_context(surface_kind, transport_options) do
    [surface_kind: surface_kind, transport_options: transport_options]
  end

  defp legacy_resolution_mode(:local), do: :local_path
  defp legacy_resolution_mode(:remote), do: :nonlocal_path

  defp nonlocal_path_resolution?(settings) do
    Map.get(settings, :resolution_mode) == :nonlocal_path
  end

  defp remote_default_command(settings) when is_map(settings) do
    case Map.get(settings, :remote_default_command) do
      value when is_binary(value) and value != "" ->
        value

      _other ->
        Map.get(settings, :default_command)
    end
  end

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
    case explicit_path(command, %{allow_js_entrypoint: false}) do
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
      String.contains?(expanded, "/.asdf/shims/") or shim_script_contains?(expanded, "asdf exec") ->
        :asdf

      String.contains?(expanded, "/.local/share/mise/shims/") or
        String.contains?(expanded, "/.mise/shims/") or
          shim_script_contains?(expanded, "mise exec") ->
        :mise

      String.contains?(expanded, "/.rtx/shims/") or shim_script_contains?(expanded, "rtx exec") ->
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

  defp shim_script_contains?(path, marker) when is_binary(path) and is_binary(marker) do
    if shims_directory?(path) and shell_script?(path) do
      file_contains?(path, marker)
    else
      false
    end
  end

  defp shims_directory?(path) when is_binary(path) do
    Path.dirname(path) |> Path.basename() == "shims"
  end

  defp shell_script?(path) when is_binary(path) do
    case read_first_line(path) do
      {:ok, <<"#!", remainder::binary>>} ->
        case parse_shebang(remainder) do
          {:ok, {command, _command_prefix}} -> shell_command?(command)
          _other -> false
        end

      _other ->
        false
    end
  end

  defp shell_command?(command) when is_binary(command) do
    Path.basename(command) in ["ash", "bash", "dash", "fish", "ksh", "sh", "zsh"]
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

  defp default_known_locations(:amp) do
    home = System.get_env("HOME") || System.user_home!()

    [
      Path.join([home, ".amp", "bin", "amp"]),
      Path.join([home, ".local", "bin", "amp"])
    ]
  end

  defp default_known_locations(:claude) do
    home = System.user_home!()

    [
      Path.join([home, ".npm-global", "bin", "claude"]),
      "/usr/local/bin/claude",
      Path.join([home, ".local", "bin", "claude"]),
      Path.join([home, "node_modules", ".bin", "claude"]),
      Path.join([home, ".yarn", "bin", "claude"]),
      Path.join([home, ".claude", "local", "claude"])
    ]
  end

  defp default_known_locations(_provider), do: []

  defp run_lookup_steps(steps, settings) when is_list(steps) do
    Enum.reduce_while(steps, :miss, fn step, :miss ->
      case step.(settings) do
        :miss -> {:cont, :miss}
        result -> {:halt, result}
      end
    end)
  end

  defp find_executable_candidate(command, _settings) when is_binary(command) do
    System.find_executable(command)
  end

  defp js_entrypoint?(path, %{allow_js_entrypoint: true}) when is_binary(path) do
    String.ends_with?(path, ".js")
  end

  defp js_entrypoint?(_path, _settings), do: false

  defp wrap_js_entrypoint(path, settings) when is_binary(path) do
    node_command = Map.get(settings, :node_command, "node")

    case resolve_command_path(node_command) do
      {:ok, node_path} ->
        stabilized_node_path =
          case stabilize_program(node_path, settings) do
            :unchanged -> node_path
            {:ok, stabilized} -> stabilized
            {:error, _reason} -> node_path
          end

        {:ok, CommandSpec.new(stabilized_node_path, argv_prefix: [path])}

      :miss ->
        {:error, :node_not_found}
    end
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

  defp reason_message(env_var, value, :node_not_found),
    do: "#{env_var} points to a JavaScript launcher but node could not be found: #{value}"

  defp unwrap_runtime_reason({:transport, %TransportError{} = error}), do: error
  defp unwrap_runtime_reason(%TransportError{} = error), do: error
  defp unwrap_runtime_reason(%ProcessExit{} = exit), do: exit
  defp unwrap_runtime_reason(reason), do: reason

  defp transport_runtime_failure(settings, %TransportError{} = error, context) do
    case error.reason do
      {:command_not_found, _command} ->
        runtime_failure_struct(
          settings,
          :cli_not_found,
          cli_not_found_message(settings, context),
          error,
          context
        )

      {:cwd_not_found, cwd} ->
        runtime_failure_struct(
          settings,
          :cwd_not_found,
          cwd_not_found_message(context, cwd),
          error,
          Map.put(context, :cwd, cwd)
        )

      other ->
        runtime_failure_struct(
          settings,
          :transport_error,
          "#{settings.display_name} transport failed#{placement_suffix(context)}: #{inspect(other)}",
          error,
          context
        )
    end
  end

  defp process_exit_runtime_failure(settings, %ProcessExit{} = exit, context) do
    context =
      context
      |> Map.put(:exit_code, exit.code)
      |> maybe_put(:stderr, exit.stderr)

    cond do
      cwd_not_found_exit?(exit, context) ->
        runtime_failure_struct(
          settings,
          :cwd_not_found,
          cwd_not_found_message(context, detect_cwd_from_exit(exit, context)),
          exit,
          context
        )

      cli_not_found_exit?(settings, exit) ->
        runtime_failure_struct(
          settings,
          :cli_not_found,
          cli_not_found_message(settings, context),
          exit,
          context
        )

      auth_error_exit?(exit) ->
        runtime_failure_struct(
          settings,
          :auth_error,
          auth_error_message(settings, context),
          exit,
          context
        )

      true ->
        runtime_failure_struct(
          settings,
          :process_exit,
          generic_exit_message(settings, exit, context),
          exit,
          context
        )
    end
  end

  defp generic_runtime_failure(settings, reason, context) do
    runtime_failure_struct(
      settings,
      :transport_error,
      "#{settings.display_name} failed#{placement_suffix(context)}: #{inspect(reason)}",
      reason,
      context
    )
  end

  defp runtime_failure_struct(settings, kind, message, cause, context) do
    %ErrorRuntimeFailure{
      kind: kind,
      provider: settings.provider,
      message: message,
      exit_code: Map.get(context, :exit_code),
      stderr: Map.get(context, :stderr),
      context: context,
      cause: cause
    }
  end

  defp runtime_failure_context(settings, opts) do
    execution_surface = Keyword.get(opts, :execution_surface)
    command = Keyword.get(opts, :command)
    cwd = Keyword.get(opts, :cwd)
    stderr = normalize_stderr(Keyword.get(opts, :stderr))
    remote? = ExecutionSurface.remote_surface?(execution_surface)
    nonlocal_path? = ExecutionSurface.nonlocal_path_surface?(execution_surface)
    path_semantics = ExecutionSurface.path_semantics(execution_surface)
    destination = surface_destination(execution_surface)

    %{
      provider: settings.provider,
      display_name: settings.display_name,
      command: command,
      cwd: cwd,
      remote?: remote?,
      nonlocal_path?: nonlocal_path?,
      path_semantics: path_semantics,
      destination: destination,
      stderr: stderr
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp cli_not_found_exit?(settings, %ProcessExit{} = exit) do
    stderr = normalize_stderr(exit.stderr)

    cond do
      match?({:command_not_found, _}, exit.reason) ->
        true

      exit.code == 127 and command_not_found_stderr?(settings, stderr) ->
        true

      true ->
        false
    end
  end

  defp cwd_not_found_exit?(%ProcessExit{} = exit, context) do
    stderr = normalize_stderr(exit.stderr)
    cwd = Map.get(context, :cwd)

    cond do
      is_binary(cwd) and stderr =~ "cd: #{cwd}: No such file or directory" ->
        true

      is_binary(parse_missing_cwd(stderr)) ->
        true

      true ->
        false
    end
  end

  defp auth_error_exit?(%ProcessExit{} = exit) do
    stderr = normalize_stderr(exit.stderr)

    is_binary(stderr) and auth_error_text?(stderr)
  end

  defp command_not_found_stderr?(settings, stderr) when is_binary(stderr) do
    command_names =
      [
        Map.get(settings, :default_command),
        Map.get(settings, :path_candidates, [])
      ]
      |> List.flatten()
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    missing_phrase? = command_not_found_text?(stderr)

    cond do
      not missing_phrase? ->
        false

      command_names == [] ->
        true

      true ->
        stderr_downcased = String.downcase(stderr)

        Enum.any?(command_names, fn command_name ->
          stderr_downcased =~ String.downcase(command_name)
        end)
    end
  end

  defp command_not_found_stderr?(_settings, _stderr), do: false

  defp detect_cwd_from_exit(%ProcessExit{} = exit, context) do
    Map.get(context, :cwd) || parse_missing_cwd(normalize_stderr(exit.stderr))
  end

  defp parse_missing_cwd(stderr) when is_binary(stderr) do
    stderr
    |> case_insensitive_between("cd:", ": no such file or directory")
    |> normalize_optional_text()
  end

  defp parse_missing_cwd(_stderr), do: nil

  defp auth_error_text?(text) when is_binary(text) do
    lower = String.downcase(text)

    contains_any?(lower, [
      "not authenticated",
      "authentication required",
      "please log in",
      "please login",
      "requires login"
    ]) or contains_ordered?(lower, ["run ", " login"])
  end

  defp command_not_found_text?(text) when is_binary(text) do
    text
    |> String.downcase()
    |> contains_any?(["command not found", "not found", "no such file or directory"])
  end

  defp case_insensitive_between(text, prefix, suffix)
       when is_binary(text) and is_binary(prefix) and is_binary(suffix) do
    lower = String.downcase(text)

    case :binary.match(lower, prefix) do
      {prefix_start, prefix_size} ->
        search_start = prefix_start + prefix_size
        search_size = byte_size(lower) - search_start
        lower_after_prefix = binary_part(lower, search_start, search_size)

        case :binary.match(lower_after_prefix, suffix) do
          {suffix_start, _suffix_size} -> binary_part(text, search_start, suffix_start)
          :nomatch -> nil
        end

      :nomatch ->
        nil
    end
  end

  defp normalize_optional_text(nil), do: nil

  defp normalize_optional_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      value -> value
    end
  end

  defp contains_any?(text, phrases) when is_binary(text) and is_list(phrases) do
    Enum.any?(phrases, &String.contains?(text, &1))
  end

  defp contains_ordered?(text, phrases) when is_binary(text) and is_list(phrases) do
    {_position, matched?} =
      Enum.reduce_while(phrases, {0, true}, fn phrase, {position, true} ->
        remainder = binary_part(text, position, byte_size(text) - position)

        case :binary.match(remainder, phrase) do
          {match_position, phrase_size} ->
            {:cont, {position + match_position + phrase_size, true}}

          :nomatch ->
            {:halt, {position, false}}
        end
      end)

    matched?
  end

  defp cli_not_found_message(settings, context) do
    base = cli_not_found(settings.provider, settings).message

    if Map.get(context, :nonlocal_path?) do
      base
      |> String.replace(
        " not found.",
        " not found#{placement_suffix(context)}."
      )
      |> Kernel.<>(path_hint(context))
    else
      base
    end
  end

  defp cwd_not_found_message(context, cwd) do
    target = cwd || "the requested working directory"
    "Working directory #{target} does not exist#{placement_suffix(context)}"
  end

  defp auth_error_message(settings, context) do
    "#{settings.display_name} requires authentication#{placement_suffix(context)}. #{auth_hint(settings.provider)}"
  end

  defp generic_exit_message(settings, %ProcessExit{} = exit, context) do
    base =
      cond do
        is_integer(exit.code) ->
          "#{settings.display_name} exited with code #{exit.code}"

        exit.status == :signal ->
          "#{settings.display_name} terminated by signal #{inspect(exit.signal)}"

        true ->
          "#{settings.display_name} exited with #{inspect(exit.reason)}"
      end

    stderr = normalize_stderr(exit.stderr)

    if is_binary(stderr) and stderr != "" do
      "#{base}#{placement_suffix(context)}: #{stderr}"
    else
      "#{base}#{placement_suffix(context)}"
    end
  end

  defp auth_hint(:claude), do: "Run `claude login` on the target and retry."
  defp auth_hint(:codex), do: "Authenticate Codex on the target and retry."
  defp auth_hint(:gemini), do: "Authenticate Gemini CLI on the target and retry."
  defp auth_hint(:amp), do: "Authenticate Amp CLI on the target and retry."
  defp auth_hint(_provider), do: "Authenticate the CLI on the target and retry."

  defp path_hint(%{path_semantics: :guest}), do: guest_path_hint()
  defp path_hint(%{remote?: true}), do: remote_path_hint()
  defp path_hint(%{nonlocal_path?: true}), do: nonlocal_path_hint()
  defp path_hint(_context), do: ""

  defp remote_path_hint do
    " If the CLI is installed outside the remote non-login PATH, pass an explicit CLI path or PATH env override."
  end

  defp guest_path_hint do
    " If the CLI is not on the guest PATH, pass an explicit CLI path or guest PATH env override."
  end

  defp nonlocal_path_hint do
    " If the CLI is not on the target PATH, pass an explicit CLI path or PATH env override."
  end

  defp placement_suffix(%{path_semantics: :guest}), do: " on the attached guest surface"

  defp placement_suffix(%{remote?: true, destination: destination})
       when is_binary(destination) and destination != "" do
    " on remote target #{destination}"
  end

  defp placement_suffix(%{remote?: true}), do: " on the remote target"
  defp placement_suffix(%{nonlocal_path?: true}), do: " on the non-local execution surface"
  defp placement_suffix(_context), do: ""

  defp surface_destination(%ExecutionSurface{} = execution_surface) do
    if ExecutionSurface.remote_surface?(execution_surface) do
      Keyword.get(execution_surface.transport_options, :destination)
    end
  end

  defp surface_destination(execution_surface) when is_list(execution_surface) do
    case ExecutionSurface.new(execution_surface) do
      {:ok, %ExecutionSurface{} = normalized} -> surface_destination(normalized)
      {:error, _reason} -> nil
    end
  end

  defp surface_destination(%{} = execution_surface) do
    execution_surface
    |> execution_surface_surface_opts()
    |> surface_destination()
  end

  defp surface_destination(_other), do: nil

  defp execution_surface_surface_opts(execution_surface) when is_map(execution_surface) do
    [
      surface_kind:
        Map.get(execution_surface, :surface_kind, Map.get(execution_surface, "surface_kind")),
      transport_options:
        Map.get(
          execution_surface,
          :transport_options,
          Map.get(execution_surface, "transport_options")
        )
    ]
  end

  defp normalize_stderr(stderr) when is_binary(stderr) do
    stderr
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_stderr(_stderr), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
