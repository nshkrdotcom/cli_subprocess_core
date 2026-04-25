defmodule CliSubprocessCore.ExecutionPlaneIntegrationTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Command.Options, as: CommandOptions
  alias CliSubprocessCore.Command.RunResult, as: CommandRunResult
  alias CliSubprocessCore.ExecutionSurface
  alias CliSubprocessCore.RawSession
  alias CliSubprocessCore.Session.Options, as: SessionOptions
  alias CliSubprocessCore.TestSupport.ProviderProfiles.CommandRunner
  alias CliSubprocessCore.TestSupport.ProviderProfiles.Echo
  alias ExecutionPlane.Process.Transport
  alias ExecutionPlane.Process.Transport.Info
  alias ExecutionPlane.Process.Transport.RunResult

  test "command options build the compatibility execution-surface contract" do
    invocation = Command.new("printf", ["ready"])

    assert {:ok, options} =
             CommandOptions.new(
               invocation,
               execution_surface: [
                 surface_kind: :ssh_exec,
                 target_id: "target-1",
                 transport_options: [destination: "ssh.example"]
               ]
             )

    assert %ExecutionSurface{} = execution_surface = CommandOptions.execution_surface(options)
    assert execution_surface.surface_kind == :ssh_exec
    assert execution_surface.target_id == "target-1"
    assert execution_surface.transport_options[:destination] == "ssh.example"
  end

  test "session options build the compatibility execution-surface contract" do
    assert {:ok, options} =
             SessionOptions.new(
               profile: Echo,
               prompt: "hello",
               execution_surface: [
                 surface_kind: :guest_bridge,
                 surface_ref: "surface-1",
                 transport_options: [
                   endpoint: %{kind: :tcp, host: "127.0.0.1", port: 40_321},
                   bridge_ref: "bridge-1",
                   bridge_profile: "core_cli_transport",
                   supported_protocol_versions: [1]
                 ]
               ]
             )

    assert %ExecutionSurface{} = execution_surface = SessionOptions.execution_surface(options)
    assert execution_surface.surface_kind == :guest_bridge
    assert execution_surface.surface_ref == "surface-1"
    assert execution_surface.transport_options[:bridge_ref] == "bridge-1"
  end

  test "raw session defaults to the execution-plane session transport" do
    script = create_test_script("printf 'ready\\n'")

    assert {:ok, session} = RawSession.start(script, [], stdin?: false)
    assert session.transport_api == Transport
    assert %{transport: %Info{surface_kind: :local_subprocess}} = RawSession.info(session)

    assert {:ok, %RunResult{} = result} = RawSession.collect(session, 2_000)
    assert result.output =~ "ready"
  end

  test "command run returns the core command result type" do
    script = create_test_script("printf 'runner-ok'")

    assert {:ok, %CommandRunResult{} = result} =
             Command.run(
               profile: CommandRunner,
               command: script,
               args: ["--ignored"]
             )

    assert result.invocation.command == script
    assert result.output == "runner-ok"
    assert result.execution_provenance.kind == "direct_lower_lane_owner"
    assert result.execution_provenance.owner == "cli_subprocess_core"
    assert result.execution_provenance.details == %{"surface_kind" => "local_subprocess"}
  end

  defp create_test_script(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_execution_plane_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    path = Path.join(dir, "fixture.sh")

    File.write!(path, """
    #!/usr/bin/env bash
    set -euo pipefail
    #{body}
    """)

    File.chmod!(path, 0o755)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    path
  end
end
