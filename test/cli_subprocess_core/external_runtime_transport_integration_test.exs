defmodule CliSubprocessCore.ExternalRuntimeTransportIntegrationTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Command.Options, as: CommandOptions
  alias CliSubprocessCore.RawSession
  alias CliSubprocessCore.Session.Options, as: SessionOptions
  alias CliSubprocessCore.TestSupport.ProviderProfiles.CommandRunner
  alias CliSubprocessCore.TestSupport.ProviderProfiles.Echo
  alias ExternalRuntimeTransport.ExecutionSurface
  alias ExternalRuntimeTransport.Transport
  alias ExternalRuntimeTransport.Transport.Info
  alias ExternalRuntimeTransport.Transport.RunResult

  test "command options build the external execution-surface contract" do
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

  test "session options build the external execution-surface contract" do
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

  test "raw session defaults to the extracted transport substrate" do
    script = create_test_script("printf 'ready\\n'")

    assert {:ok, session} = RawSession.start(script, [], stdin?: false)
    assert session.transport_api == Transport
    assert %{transport: %Info{surface_kind: :local_subprocess}} = RawSession.info(session)

    assert {:ok, %RunResult{} = result} = RawSession.collect(session, 2_000)
    assert result.output =~ "ready"
  end

  test "command run returns the extracted transport result type" do
    script = create_test_script("printf 'runner-ok'")

    assert {:ok, %RunResult{} = result} =
             Command.run(
               profile: CommandRunner,
               command: script,
               args: ["--ignored"]
             )

    assert result.invocation.command == script
    assert result.output == "runner-ok"
  end

  defp create_test_script(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_external_runtime_transport_#{System.unique_integer([:positive])}"
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
