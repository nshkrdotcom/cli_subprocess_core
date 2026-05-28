defmodule CliSubprocessCore.ProviderProfiles.Antigravity do
  @moduledoc """
  Built-in provider profile for the Antigravity CLI (`agy`).

  `agy --print` emits plain text on stdout, not JSONL. Non-empty stdout lines
  are normalized as assistant deltas; stderr and process exit handling use the
  shared provider machinery.
  """

  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderFeatures
  alias CliSubprocessCore.ProviderProfiles.Shared

  @impl true
  def id, do: :antigravity

  @impl true
  def capabilities do
    [:sandbox, :streaming, :directory_mapping, :continuation]
  end

  @impl true
  def build_invocation(opts) when is_list(opts) do
    with {:ok, prompt} <- Shared.required_binary_option(opts, :prompt),
         {:ok, command_spec} <-
           Shared.resolve_command_spec(opts, :antigravity, "agy", [:cli_path]) do
      args = ["--print", prompt] ++ option_flags(opts)
      {:ok, Shared.command(command_spec, args, opts)}
    end
  end

  @impl true
  def init_parser_state(opts), do: Shared.init_parser_state(id(), opts)

  @impl true
  def decode_stdout(line, state) when is_binary(line) and is_map(state) do
    case String.trim(line) do
      "" ->
        {[], state}

      content ->
        Shared.emit_single(
          :assistant_delta,
          Payload.AssistantDelta.new(content: content),
          line,
          state
        )
    end
  end

  @impl true
  def decode_stderr(chunk, state), do: Shared.decode_stderr(chunk, state)

  @impl true
  def handle_exit(reason, state), do: Shared.handle_exit(reason, state)

  @impl true
  def transport_options(opts) do
    Shared.transport_options(opts)
    |> Keyword.put(:close_stdin_on_start?, true)
  end

  defp option_flags(opts) do
    []
    |> Shared.maybe_add_flag("--sandbox", Keyword.get(opts, :sandbox, false))
    |> Shared.maybe_add_flag(
      "--dangerously-skip-permissions",
      Keyword.get(opts, :dangerously_skip_permissions, false)
    )
    |> Shared.maybe_add_pair("--conversation", Keyword.get(opts, :conversation))
    |> Shared.maybe_add_flag("--continue", Keyword.get(opts, :continue, false))
    |> Shared.maybe_add_pair("--print-timeout", Keyword.get(opts, :print_timeout))
    |> Shared.maybe_add_pair("--log-file", Keyword.get(opts, :log_file))
    |> add_dirs(Keyword.get(opts, :add_dirs, []))
    |> Kernel.++(permission_flags(opts))
  end

  defp permission_flags(opts) do
    mode = Shared.permission_mode(opts)

    if Keyword.get(opts, :dangerously_skip_permissions, false) and bypass_mode?(mode) do
      []
    else
      ProviderFeatures.permission_args(id(), mode)
    end
  end

  defp bypass_mode?(mode) when mode in [:bypass, :dangerously_skip_permissions], do: true

  defp bypass_mode?(mode) when mode in ["bypass", "dangerously_skip_permissions"], do: true

  defp bypass_mode?(_mode), do: false

  defp add_dirs(args, dirs) when is_list(dirs) do
    Enum.reduce(dirs, args, fn
      dir, acc when is_binary(dir) ->
        Shared.maybe_add_pair(acc, "--add-dir", dir)

      _dir, acc ->
        acc
    end)
  end

  defp add_dirs(args, _dirs), do: args
end
