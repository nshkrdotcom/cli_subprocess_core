defmodule CliSubprocessCore.DependencySourcesTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @config_path Path.join(@repo_root, "build_support/dependency_sources.config.exs")

  # The ecosystem convention, and the reason it is not negotiable here: `mix`
  # unifies dependencies by APP NAME, and `:execution_plane` names two
  # different release shapes — `core/execution_plane` (core only) and the
  # historical `execution_plane 0.1.0` monolith (core + process + jsonrpc).
  # Every sibling repository that declares Execution Plane pins the canonical
  # component paths, so a graph containing this package and any of them can
  # resolve only if this package pins them too. Pointing `:execution_plane` at
  # the historical monolith creates duplicate process and JSON-RPC modules.
  @canonical_components %{
    execution_plane: "core/execution_plane",
    execution_plane_process: "runtimes/execution_plane_process",
    execution_plane_jsonrpc: "protocols/execution_plane_jsonrpc"
  }
  @hex_requirements %{
    execution_plane: "~> 0.2.0",
    execution_plane_process: "~> 0.1.0",
    execution_plane_jsonrpc: "~> 0.1.0"
  }

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_dependency_sources_#{System.unique_integer([:positive])}"
      )

    repo_root = Path.join(tmp_root, "cli_subprocess_core")
    File.mkdir_p!(Path.join(repo_root, "build_support"))
    File.cp!(@config_path, Path.join(repo_root, "build_support/dependency_sources.config.exs"))

    on_exit(fn -> File.rm_rf!(tmp_root) end)

    {:ok, repo_root: repo_root, tmp_root: tmp_root}
  end

  test "the manifest declares exactly the canonical Execution Plane components" do
    config = DependencySources.config!(@repo_root)
    deps = Map.fetch!(config, :deps)

    assert Enum.sort(Map.keys(deps)) == Enum.sort(Map.keys(@canonical_components))

    for {app, subdir} <- @canonical_components do
      dep = Map.fetch!(deps, app)

      assert dep.path == "../execution_plane/#{subdir}",
             "#{app} must pin the canonical component path the rest of the ecosystem uses"

      assert dep.github.repo == "nshkrdotcom/execution_plane"
      assert dep.github.subdir == subdir
      assert dep.hex == Map.fetch!(@hex_requirements, app)
      assert dep.default_order == [:path, :github, :hex]
      assert dep.publish_order == [:hex]
    end
  end

  test "no component points at the historical monolith artifact" do
    config = DependencySources.config!(@repo_root)

    paths =
      config
      |> Map.fetch!(:deps)
      |> Enum.map(fn {_app, dep} -> dep.path end)

    refute Enum.any?(paths, &String.contains?(&1, "dist/monolith")),
           "the monolith bundles all three components under the single app name " <>
             ":execution_plane, which cannot coexist with a sibling that pins core only"
  end

  test "a clean clone falls back to the component subdirectories", %{repo_root: repo_root} do
    deps = DependencySources.deps(repo_root, publish?: false, notify?: false)

    for {app, subdir} <- @canonical_components do
      assert {^app, opts} = List.keyfind(deps, app, 0)
      assert opts[:github] == "nshkrdotcom/execution_plane"
      assert opts[:subdir] == subdir
    end
  end

  test "sibling component checkouts switch clone mode to path", %{
    repo_root: repo_root,
    tmp_root: tmp_root
  } do
    for {_app, subdir} <- @canonical_components do
      File.mkdir_p!(Path.join(tmp_root, "execution_plane/#{subdir}"))
    end

    deps = DependencySources.deps(repo_root, publish?: false, notify?: false)

    for {app, subdir} <- @canonical_components do
      assert {^app, opts} = List.keyfind(deps, app, 0)
      assert opts[:path] == Path.join(tmp_root, "execution_plane/#{subdir}")
    end
  end

  test "publish mode resolves every component from Hex" do
    deps = DependencySources.deps(@repo_root, publish?: true, notify?: false)

    for {app, requirement} <- @hex_requirements do
      assert {^app, ^requirement} = List.keyfind(deps, app, 0)
    end

    refute String.contains?(inspect(deps), "path:")
    refute String.contains?(inspect(deps), "github:")
  end
end
