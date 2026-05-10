defmodule CliSubprocessCore.DependencySourcesTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @config_path Path.join(@repo_root, "build_support/dependency_sources.config.exs")

  test "Execution Plane dependencies prefer local paths and fall back to GitHub then Hex" do
    {config, _binding} = Code.eval_file(@config_path)

    deps = Map.fetch!(config, :deps)

    for app <- [:execution_plane, :execution_plane_jsonrpc, :execution_plane_process] do
      dep = Map.fetch!(deps, app)

      assert dep.default_order == [:path, :github, :hex]
      assert dep.publish_order == [:hex]
      assert dep.path
      assert dep.github.repo == "nshkrdotcom/execution_plane"
      assert dep.github.branch == "main"
      assert dep.github.subdir
      assert dep.hex == "~> 0.1.0"
    end
  end
end
