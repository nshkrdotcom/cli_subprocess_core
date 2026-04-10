defmodule CliSubprocessCore.DocumentationContractTest do
  use ExUnit.Case, async: true

  @doc_paths ["README.md"] ++ Path.wildcard("guides/*.md") ++ Path.wildcard("examples/*.md")
  @self_path Path.relative_to_cwd(__ENV__.file)
  @code_paths Path.wildcard("lib/**/*.ex") ++
                Enum.reject(Path.wildcard("test/**/*.exs"), &(&1 == @self_path))
  @legacy_doc_tokens [
    "CliSubprocessCore.Transport",
    "CliSubprocessCore.ProcessExit",
    ":exec.stop/1",
    ":exec.kill",
    ":kill_group",
    "shared exec worker"
  ]
  @owner_drift_tokens [
    ["external", "_", "runtime", "_", "transport"] |> Enum.join(),
    ["external", "-", "runtime", "-", "transport"] |> Enum.join(),
    ["External", "Runtime", "Transport"] |> Enum.join()
  ]
  @substrate_internal_tokens [
    "Process.whereis(:exec)",
    ":exec.kill",
    ":exec.stop",
    ":kill_group",
    "Application.ensure_all_started(:erlexec)"
  ]

  test "public docs stay on the extracted transport boundary" do
    offenders = collect_token_matches(@doc_paths, @legacy_doc_tokens)

    assert offenders == [],
           "legacy transport references remain in docs:\n#{format_offenders(offenders)}"
  end

  test "public docs do not retain removed legacy transport references" do
    offenders = collect_token_matches(@doc_paths, @owner_drift_tokens)

    assert offenders == [],
           "removed legacy transport references remain in docs:\n#{format_offenders(offenders)}"
  end

  test "core code and tests do not own raw substrate internals" do
    offenders = collect_token_matches(@code_paths, @substrate_internal_tokens)

    assert offenders == [],
           "raw substrate internals leaked into cli_subprocess_core:\n#{format_offenders(offenders)}"
  end

  test "hexdocs navigation includes every guide and examples readme" do
    extras =
      Mix.Project.config()
      |> Keyword.fetch!(:docs)
      |> Keyword.fetch!(:extras)
      |> Enum.map(&extra_path/1)
      |> MapSet.new()

    expected =
      ["examples/README.md" | Path.wildcard("guides/*.md")]
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    assert MapSet.subset?(expected, extras),
           "missing HexDocs extras: #{inspect(MapSet.to_list(MapSet.difference(expected, extras)))}"
  end

  defp collect_token_matches(paths, tokens) do
    Enum.flat_map(paths, fn path ->
      path
      |> File.read!()
      |> offending_tokens(tokens)
      |> case do
        [] -> []
        matches -> [{path, matches}]
      end
    end)
  end

  defp offending_tokens(contents, tokens) do
    Enum.filter(tokens, &String.contains?(contents, &1))
  end

  defp extra_path({path, _opts}) when is_atom(path), do: Atom.to_string(path)
  defp extra_path({path, _opts}) when is_binary(path), do: path
  defp extra_path(path) when is_atom(path), do: Atom.to_string(path)
  defp extra_path(path) when is_binary(path), do: path

  defp format_offenders(offenders) do
    Enum.map_join(offenders, "\n", fn {path, matches} ->
      "#{path}: #{Enum.join(matches, ", ")}"
    end)
  end
end
