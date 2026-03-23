defmodule CliSubprocessCore.TestSupport.ProviderProfiles.CommandRunner do
  @moduledoc false

  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.Command

  @impl true
  def id, do: :command_runner

  @impl true
  def capabilities, do: [:batch]

  @impl true
  def build_invocation(opts) when is_list(opts) do
    case Keyword.get(opts, :command) do
      value when is_binary(value) and value != "" ->
        {:ok,
         Command.new(value, normalize_args(Keyword.get(opts, :args, [])),
           cwd: Keyword.get(opts, :cwd),
           env: normalize_env(Keyword.get(opts, :env, %{}))
         )}

      _other ->
        {:error, {:missing_option, :command}}
    end
  end

  @impl true
  def init_parser_state(_opts), do: nil

  @impl true
  def decode_stdout(_data, state), do: {[], state}

  @impl true
  def decode_stderr(_data, state), do: {[], state}

  @impl true
  def handle_exit(_reason, state), do: {[], state}

  @impl true
  def transport_options(_opts), do: []

  defp normalize_args(args) when is_list(args) do
    Enum.flat_map(args, fn
      value when is_binary(value) -> [value]
      _other -> []
    end)
  end

  defp normalize_args(_args), do: []

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env(env) when is_list(env) do
    env
    |> Enum.filter(&match?({_, _}, &1))
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env(_env), do: %{}
end
