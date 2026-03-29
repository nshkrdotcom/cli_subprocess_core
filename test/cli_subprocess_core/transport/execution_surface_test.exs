defmodule CliSubprocessCore.ExecutionSurfaceTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ExecutionSurface

  test "resolve/1 keeps adapter-module selection internal while normalizing the transport lane" do
    assert {:ok, resolved} =
             ExecutionSurface.resolve(
               command: "cat",
               target_id: "target-1",
               startup_mode: :lazy,
               stdout_mode: :raw
             )

    refute Map.has_key?(resolved, :adapter)
    assert is_function(resolved.dispatch.start, 1)
    assert is_function(resolved.dispatch.start_link, 1)
    assert is_function(resolved.dispatch.run, 2)
    assert resolved.surface.surface_kind == :local_subprocess
    assert resolved.surface.target_id == "target-1"
    assert resolved.adapter_options[:command] == "cat"
    assert resolved.adapter_options[:startup_mode] == :lazy
    assert resolved.adapter_options[:stdout_mode] == :raw
    assert resolved.adapter_options[:target_id] == "target-1"
  end

  test "resolve/1 supports the SSH execution surface through the generic lane" do
    assert {:ok, ssh_exec} =
             ExecutionSurface.resolve(
               command: "cat",
               surface_kind: :ssh_exec,
               target_id: "ssh-target-1",
               transport_options: %{destination: "ssh.example"}
             )

    assert ssh_exec.surface.surface_kind == :ssh_exec
    assert ssh_exec.adapter_options[:target_id] == "ssh-target-1"
    assert ssh_exec.adapter_options[:transport_options] == [destination: "ssh.example"]
  end

  test "resolve/1 accepts canonical execution_surface inputs" do
    assert {:ok, resolved} =
             ExecutionSurface.resolve(
               command: "cat",
               execution_surface: %{
                 "surface_kind" => :ssh_exec,
                 "target_id" => "ssh-target-2",
                 "transport_options" => %{"destination" => "ssh.canonical.example"}
               }
             )

    assert resolved.surface.surface_kind == :ssh_exec
    assert resolved.surface.target_id == "ssh-target-2"
    assert resolved.adapter_options[:transport_options] == [destination: "ssh.canonical.example"]
  end

  test "resolve/1 accepts guest bridge execution surfaces through the generic lane" do
    assert {:ok, resolved} =
             ExecutionSurface.resolve(
               command: "cat",
               execution_surface: %{
                 "surface_kind" => :guest_bridge,
                 "surface_ref" => "surface-guest-1",
                 "transport_options" => %{
                   "endpoint" => %{
                     "kind" => "tcp",
                     "host" => "127.0.0.1",
                     "port" => 40_321
                   },
                   "bridge_ref" => "bridge-1",
                   "bridge_profile" => "core_cli_transport",
                   "supported_protocol_versions" => [1]
                 }
               }
             )

    assert resolved.surface.surface_kind == :guest_bridge
    assert resolved.surface.surface_ref == "surface-guest-1"
    assert resolved.adapter_options[:surface_ref] == "surface-guest-1"

    assert resolved.adapter_options[:transport_options] == [
             endpoint: %{kind: :tcp, host: "127.0.0.1", port: 40_321},
             bridge_ref: "bridge-1",
             attach_token: nil,
             bridge_profile: "core_cli_transport",
             supported_protocol_versions: [1],
             extensions: %{},
             connect_timeout_ms: nil,
             request_timeout_ms: nil
           ]
  end
end
