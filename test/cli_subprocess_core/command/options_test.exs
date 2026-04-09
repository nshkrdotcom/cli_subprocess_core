defmodule CliSubprocessCore.Command.OptionsTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Command.Options
  alias CliSubprocessCore.TestSupport.ProviderProfiles.CommandRunner

  test "reserves canonical execution_surface input off the provider lane" do
    assert {:ok, %Options{} = options} =
             Options.new(
               profile: CommandRunner,
               command: "/bin/sh",
               args: ["-c", "printf ready"],
               execution_surface: [
                 surface_kind: :local_subprocess,
                 target_id: "target-1",
                 lease_ref: "lease-1",
                 surface_ref: "surface-1",
                 boundary_class: :local,
                 observability: %{suite: :phase_b},
                 transport_options: [connect_timeout_ms: 1_500]
               ]
             )

    assert options.provider_options == [command: "/bin/sh", args: ["-c", "printf ready"]]
    assert options.surface_kind == :local_subprocess
    assert options.target_id == "target-1"
    assert options.lease_ref == "lease-1"
    assert options.surface_ref == "surface-1"
    assert options.boundary_class == :local
    assert options.observability == %{suite: :phase_b}
    assert options.transport_options == [connect_timeout_ms: 1_500]
  end

  test "accepts execution-plane-only surface kinds" do
    assert {:ok, %Options{} = options} =
             Options.new(
               profile: CommandRunner,
               command: "/bin/sh",
               args: ["-c", "printf ready"],
               execution_surface: [surface_kind: :test_guest_local]
             )

    assert options.surface_kind == :test_guest_local
  end
end
