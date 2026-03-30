defmodule CliSubprocessCore.Transport.CapabilityContractTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.{Command, Transport}
  alias CliSubprocessCore.Transport.Error

  test "start/1 rejects restrictive capability declarations before adapter dispatch" do
    assert {:error,
            {:transport, %Error{reason: {:unsupported_capability, :pty, :test_restricted_spawn}}}} =
             Transport.start(command: "cat", surface_kind: :test_restricted_spawn, pty?: true)

    assert {:error,
            {:transport, %Error{reason: {:unsupported_capability, :user, :test_restricted_spawn}}}} =
             Transport.start(
               command: "cat",
               surface_kind: :test_restricted_spawn,
               user: "builder"
             )

    assert {:error,
            {:transport, %Error{reason: {:unsupported_capability, :env, :test_restricted_spawn}}}} =
             Transport.start(
               command: "cat",
               surface_kind: :test_restricted_spawn,
               env: %{"PATH" => "/tmp/bin"}
             )

    assert {:error,
            {:transport, %Error{reason: {:unsupported_capability, :cwd, :test_restricted_spawn}}}} =
             Transport.start(
               command: "cat",
               surface_kind: :test_restricted_spawn,
               cwd: "/tmp/project"
             )
  end

  test "run/2 rejects restrictive capability declarations before adapter dispatch" do
    command = Command.new("echo", [], cwd: "/tmp/project")

    assert {:error,
            {:transport, %Error{reason: {:unsupported_capability, :run, :test_restricted_spawn}}}} =
             Transport.run(command, surface_kind: :test_restricted_spawn)
  end
end
