defmodule CliSubprocessCore.DependencyBoundaryTest do
  use ExUnit.Case, async: true

  @forbidden_deps [
    :agent_session_manager,
    :claude_agent_sdk,
    :codex_sdk,
    :amp_sdk,
    :inference
  ]

  test "cli_subprocess_core does not declare ASM or provider SDK deps" do
    assert_forbidden_deps_absent(Mix.Project.config()[:deps], @forbidden_deps)
  end

  test "cli_subprocess_core declares exactly one Execution Plane dependency" do
    declared = Enum.map(Mix.Project.config()[:deps], &dep_name/1)

    assert Enum.count(declared, &(&1 == :execution_plane)) == 1
    refute :execution_plane_jsonrpc in declared
    refute :execution_plane_process in declared
  end

  test "Gemini CLI remains retired from the first-party profile registry" do
    profile_names = Enum.map(CliSubprocessCore.first_party_profile_modules(), &Atom.to_string/1)

    refute Enum.any?(profile_names, &String.contains?(&1, "Gemini"))

    assert CliSubprocessCore.ProviderProfiles.Antigravity in CliSubprocessCore.first_party_profile_modules()
  end

  defp assert_forbidden_deps_absent(deps, forbidden_deps) when is_list(deps) do
    declared = MapSet.new(Enum.map(deps, &dep_name/1))

    Enum.each(forbidden_deps, fn dep ->
      refute MapSet.member?(declared, dep),
             "cli_subprocess_core must not declare dependency on #{inspect(dep)}"
    end)
  end

  defp dep_name({name, _requirement}), do: name
  defp dep_name({name, _requirement, _opts}), do: name
end
