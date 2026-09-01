defmodule CliSubprocessCore.DependencySourcesTest do
  use ExUnit.Case, async: true

  # The ecosystem convention, and the reason it is not negotiable here: `mix`
  # unifies dependencies by APP NAME, and `:execution_plane` names two
  # different release shapes — `core/execution_plane` (core only) and the
  # historical `execution_plane 0.1.0` monolith (core + process + jsonrpc).
  # Every sibling repository that declares Execution Plane pins the canonical
  # component paths, so a graph containing this package and any of them can
  # resolve only if this package pins them too. Pointing `:execution_plane` at
  # the historical monolith creates duplicate process and JSON-RPC modules.
  @hex_requirements %{
    execution_plane: "~> 0.3.0",
    execution_plane_process: "~> 0.3.0",
    execution_plane_jsonrpc: "~> 0.2.0"
  }

  test "the standalone and publishable fallback declares the component releases" do
    deps = Mix.Project.config()[:deps]

    for {app, requirement} <- @hex_requirements do
      assert {^app, ^requirement} = List.keyfind(deps, app, 0)
    end

    refute List.keymember?(deps, :ground_plane_contracts, 0)
    refute List.keymember?(deps, :ground_plane_persistence_policy, 0)
    refute String.contains?(inspect(deps), "path:")
    refute String.contains?(inspect(deps), "github:")
  end

  test "the committed dependency surface cannot select the historical monolith" do
    deps = Mix.Project.config()[:deps]

    assert List.keymember?(deps, :execution_plane, 0)
    assert List.keymember?(deps, :execution_plane_process, 0)
    assert List.keymember?(deps, :execution_plane_jsonrpc, 0)
  end
end
