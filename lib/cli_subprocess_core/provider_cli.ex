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

  @spec resolve(atom(), keyword(), [resolve_opt()]) ::
          {:ok, CommandSpec.t()} | {:error, Error.t()}
  def resolve(provider, provider_opts \\ [], opts \\ [])
      when is_atom(provider) and is_list(provider_opts) and is_list(opts) do
    with {:ok, settings} <- build_settings(provider, opts),
         :miss <- explicit_override(provider_opts, settings),
         :miss <- env_override(settings),
         :miss <- path_lookup(settings.default_command),
         :miss <- npm_global_lookup(settings),
         :miss <- npx_lookup(settings) do
      {:error, cli_not_found(provider, settings)}
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
            explicit_string_override(value)

          _other ->
            false
        end
    end)
  end

  defp explicit_string_override(value) when is_binary(value) do
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
        case env_string_override(value) do
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

  defp env_string_override(value) when is_binary(value) do
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
