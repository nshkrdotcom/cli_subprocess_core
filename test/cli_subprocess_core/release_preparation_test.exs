defmodule CliSubprocessCore.ReleasePreparationTest do
  use ExUnit.Case, async: true

  test "0.2.0 release metadata and Elixir floor are frozen" do
    project = Mix.Project.config()

    assert project[:version] == "0.2.0"
    assert project[:elixir] == "~> 1.18"
    assert project[:docs][:source_ref] == "v0.2.0"
  end

  test "package includes consumer documentation without release tooling" do
    package_files = Mix.Project.config()[:package][:files]

    assert "guides" in package_files
    assert "examples" in package_files
    assert "build_support" in package_files
    assert "assets" in package_files

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
