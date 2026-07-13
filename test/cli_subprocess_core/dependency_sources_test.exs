defmodule CliSubprocessCore.DependencySourcesTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @config_path Path.join(@repo_root, "build_support/dependency_sources.config.exs")

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

  test "one Execution Plane dependency targets the generated artifact and projection branch" do
    {config, _binding} = Code.eval_file(@config_path)

    deps = Map.fetch!(config, :deps)
    assert Map.keys(deps) == [:execution_plane]

    dep = Map.fetch!(deps, :execution_plane)

    assert dep.path == "../execution_plane/dist/monolith/execution_plane"
    assert dep.default_order == [:path, :github, :hex]
    assert dep.publish_order == [:hex]
    assert dep.github.repo == "nshkrdotcom/execution_plane"
    assert dep.github.branch == "projection/execution_plane"
    refute Map.has_key?(dep.github, :subdir)
    assert dep.hex == "~> 0.1.0"
  end

  test "clean clone mode selects the root projection branch", %{repo_root: repo_root} do
    assert [{:execution_plane, opts}] = DependencySources.deps(repo_root, publish?: false)

    assert opts[:github] == "nshkrdotcom/execution_plane"
    assert opts[:branch] == "projection/execution_plane"
    refute Keyword.has_key?(opts, :subdir)
  end

  test "a generated artifact in a clean fixture switches clone mode to path", %{
    repo_root: repo_root,
    tmp_root: tmp_root
  } do
    generated_root = Path.join(tmp_root, "execution_plane/dist/monolith/execution_plane")
    File.mkdir_p!(generated_root)

    assert [{:execution_plane, opts}] = DependencySources.deps(repo_root, publish?: false)
    assert opts[:path] == "../execution_plane/dist/monolith/execution_plane"
  end

  test "publish mode contains one Hex Execution dependency and no child packages" do
    assert [{:execution_plane, "~> 0.1.0"}] =
             DependencySources.deps(@repo_root, publish?: true)

    refute String.contains?(
             inspect(DependencySources.deps(@repo_root, publish?: true)),
             "jsonrpc"
           )

    refute String.contains?(
             inspect(DependencySources.deps(@repo_root, publish?: true)),
             "process"
           )
  end
end
