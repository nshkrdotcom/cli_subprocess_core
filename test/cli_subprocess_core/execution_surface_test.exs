defmodule CliSubprocessCore.ExecutionSurfaceTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Command.Options, as: CommandOptions
  alias CliSubprocessCore.ExecutionSurface
  alias CliSubprocessCore.Session.Options, as: SessionOptions
  alias CliSubprocessCore.TestSupport.ProviderProfiles.{CommandRunner, Echo}
  alias ExecutionPlane.Process.Transport.Surface, as: RuntimeExecutionSurface
  alias ExternalRuntimeTransport.ExecutionSurface, as: TransportExecutionSurface

  test "builds a compatibility struct from keyword input" do
    assert {:ok, %ExecutionSurface{} = surface} =
             ExecutionSurface.new(
               surface_kind: :local_subprocess,
               target_id: "target-1",
               lease_ref: "lease-1",
               surface_ref: "surface-1",
               boundary_class: :local,
               observability: %{suite: :compat},
               transport_options: [startup_mode: :lazy]
             )

    assert surface.surface_kind == :local_subprocess
    assert surface.target_id == "target-1"
    assert surface.lease_ref == "lease-1"
    assert surface.surface_ref == "surface-1"
    assert surface.boundary_class == :local
    assert surface.observability == %{suite: :compat}
    assert surface.transport_options == [startup_mode: :lazy]
  end

  test "builds a compatibility struct from map input" do
    assert {:ok, %ExecutionSurface{} = surface} =
             ExecutionSurface.new(%{
               "surface_kind" => :local_subprocess,
               "target_id" => "target-2",
               "transport_options" => %{"startup_mode" => :lazy}
             })

    assert surface.surface_kind == :local_subprocess
    assert surface.target_id == "target-2"
    assert surface.transport_options == [startup_mode: :lazy]
  end

  test "reports capabilities for the compatibility struct" do
    assert {:ok, %ExecutionSurface{} = surface} =
             ExecutionSurface.new(surface_kind: :ssh_exec)

    assert {:ok, capabilities} = ExecutionSurface.capabilities(surface)
    assert capabilities.remote? == true
    assert ExecutionSurface.remote_surface?(surface)
    assert ExecutionSurface.nonlocal_path_surface?(surface)
  end

  test "projects the compatibility surface onto the execution-plane transport surface contract" do
    assert {:ok, %ExecutionSurface{} = surface} =
             ExecutionSurface.new(
               surface_kind: :ssh_exec,
               target_id: "runtime-target",
               boundary_class: "remote_cli",
               observability: %{suite: :runtime_projection}
             )

    assert %RuntimeExecutionSurface{} =
             runtime_surface = ExecutionSurface.to_runtime_surface(surface)

    assert runtime_surface.surface_kind == :ssh_exec
    assert runtime_surface.target_id == "runtime-target"
    assert runtime_surface.boundary_class == "remote_cli"
    assert runtime_surface.observability == %{suite: :runtime_projection}

    assert RuntimeExecutionSurface.to_map(runtime_surface) == ExecutionSurface.to_map(surface)
  end

  test "exposes execution-plane-only surface capabilities through the compatibility facade" do
    assert {:ok, capabilities} = ExecutionSurface.capabilities(:test_guest_local)
    assert capabilities.remote? == false
    assert capabilities.path_semantics == :guest
    assert capabilities.supports_run? == true
    assert ExecutionSurface.nonlocal_path_surface?(:test_guest_local)
    refute ExecutionSurface.remote_surface?(:test_guest_local)
  end

  test "command options accept the compatibility execution surface" do
    assert {:ok, %ExecutionSurface{} = execution_surface} =
             ExecutionSurface.new(
               surface_kind: :local_subprocess,
               target_id: "target-command",
               observability: %{suite: :compat}
             )

    assert {:ok, %CommandOptions{} = options} =
             CommandOptions.new(
               profile: CommandRunner,
               command: "/bin/sh",
               args: ["-c", "printf ready"],
               execution_surface: execution_surface
             )

    assert options.target_id == "target-command"
    assert options.observability == %{suite: :compat}
  end

  test "session options accept the compatibility execution surface" do
    assert {:ok, %ExecutionSurface{} = execution_surface} =
             ExecutionSurface.new(
               surface_kind: :local_subprocess,
               target_id: "target-session",
               observability: %{suite: :compat}
             )

    assert {:ok, %SessionOptions{} = options} =
             SessionOptions.new(
               profile: Echo,
               prompt: "hello",
               execution_surface: execution_surface,
               subscriber: {self(), make_ref()}
             )

    assert options.target_id == "target-session"
    assert options.observability == %{suite: :compat}
  end

  test "compatibility facade preserves the contract version and string boundary classes" do
    assert {:ok, %ExecutionSurface{} = surface} =
             ExecutionSurface.new(%{
               "contract_version" => "execution_surface.v1",
               "surface_kind" => :ssh_exec,
               "boundary_class" => "remote_cli",
               "observability" => %{"suite" => "compat"}
             })

    assert surface.contract_version == "execution_surface.v1"
    assert surface.boundary_class == "remote_cli"

    assert %TransportExecutionSurface{} =
             transport_surface = ExecutionSurface.to_external(surface)

    assert transport_surface.contract_version == "execution_surface.v1"
    assert transport_surface.boundary_class == "remote_cli"
  end
end
