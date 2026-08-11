defmodule CliSubprocessCore.ReleasePreparationTest do
  use ExUnit.Case, async: true

  # Asserting a version literal here only proves someone edited this file. What
  # is load-bearing is that the version, the docs ref, and the CHANGELOG agree,
  # and that the Elixir floor has not drifted.
  test "release metadata is internally consistent and the Elixir floor holds" do
    project = Mix.Project.config()
    changelog = File.read!(Path.expand("../../CHANGELOG.md", __DIR__))

    assert project[:elixir] == "~> 1.18"
    assert project[:docs][:source_ref] == "v#{project[:version]}"

    assert [_, newest] = Regex.run(~r/^## \[(\d+\.\d+\.\d+)\]/m, changelog)
    assert project[:version] == newest
  end

  test "package includes consumer documentation without release tooling" do
    package_files = Mix.Project.config()[:package][:files]

    assert "guides" in package_files
    assert "examples" in package_files
    assert "assets" in package_files

    # 0.5.1 stopped shipping `build_support/`. `mix.exs` requires that file when
    # it is present, so a published package containing it either failed to load
    # in a consumer or handed them git dependencies instead of Hex ones. Its
    # absence is now the signal that says "this is a consumer checkout".
    refute "build_support" in package_files

    refute "scripts" in package_files
    refute "docs" in package_files
    refute ".formatter.exs" in package_files
    refute "mix.lock" in package_files
    refute "AGENTS.md" in package_files
  end

  test "generated Execution Plane exports every lower module used by core" do
    modules = [
      ExecutionPlane.Command,
      ExecutionPlane.Contracts,
      ExecutionPlane.Contracts.FailureClass,
      ExecutionPlane.ExecutionRef,
      ExecutionPlane.ExecutionRequest,
      ExecutionPlane.ExecutionResult,
      ExecutionPlane.Process,
      ExecutionPlane.Process.Transport,
      ExecutionPlane.Process.Transport.Error,
      ExecutionPlane.Process.Transport.Info,
      ExecutionPlane.Process.Transport.RunResult,
      ExecutionPlane.Process.Transport.Surface,
      ExecutionPlane.ProcessExit,
      ExecutionPlane.Protocols.JsonRpc.Adapter,
      ExecutionPlane.Provenance
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
