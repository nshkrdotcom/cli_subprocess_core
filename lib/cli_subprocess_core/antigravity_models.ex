defmodule CliSubprocessCore.AntigravityModels do
  @moduledoc """
  Lists the model slugs advertised by the active Antigravity CLI account.
  """

  alias CliSubprocessCore.{Command, ProviderCLI}
  alias CliSubprocessCore.Command.RunResult

  @type entry :: %{id: String.t(), label: String.t()}
  @type discovery_error :: :model_list_failed | :invalid_model_list

  @doc """
  Runs `agy models` through the Core command lane.

  Accepts `:cli_path`, `:cwd`, `:env`, `:clear_env?`, and a `:timeout` in
  milliseconds. Call this when refreshing an account picker. A successful empty
  list and a failed command are returned separately. Refresh the list when the
  active account changes.
  """
  @spec list(keyword()) :: {:ok, [entry()]} | {:error, discovery_error()}
  def list(opts \\ []) do
    with {:ok, executable} <- ProviderCLI.resolve(:antigravity, opts, extra_keys: [:cli_path]),
         invocation <- Command.new(executable, ["models"], opts),
         {:ok, %RunResult{} = result} <-
           Command.run(invocation, timeout: Keyword.get(opts, :timeout, 15_000)),
         true <- RunResult.success?(result) do
      parse(result.stdout)
    else
      _failure -> {:error, :model_list_failed}
    end
  end

  defp parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, &parse_line/2)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp parse_line(line, {:ok, entries}) do
    case String.split(String.trim(line), "\t", parts: 2) do
      [slug, label] when slug != "" and label != "" ->
        if Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9._:\/-]*$/, slug) do
          {:cont, {:ok, [%{id: slug, label: label} | entries]}}
        else
          {:halt, {:error, :invalid_model_list}}
        end

      [status] when status in ["", "Fetching available models..."] ->
        {:cont, {:ok, entries}}

      _other ->
        {:halt, {:error, :invalid_model_list}}
    end
  end
end
