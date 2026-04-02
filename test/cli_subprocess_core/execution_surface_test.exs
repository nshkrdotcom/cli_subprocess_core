defmodule CliSubprocessCore.ExecutionSurfaceTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Command.Options, as: CommandOptions
  alias CliSubprocessCore.ExecutionSurface
  alias CliSubprocessCore.Session.Options, as: SessionOptions
  alias CliSubprocessCore.TestSupport.ProviderProfiles.{CommandRunner, Echo}

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
end
