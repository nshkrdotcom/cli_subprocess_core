defmodule CliSubprocessCore.Transport.ExecutionSurfaceTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Transport.ExecutionSurface

  test "resolve/1 keeps adapter-module selection internal while normalizing the transport lane" do
    assert {:ok, resolved} =
             ExecutionSurface.resolve(
               command: "cat",
               target_id: "target-1",
               transport_options: %{startup_mode: :lazy, stdout_mode: :raw}
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

  test "resolve/1 supports the SSH-backed execution surfaces through the generic lane" do
    assert {:ok, static_ssh} =
             ExecutionSurface.resolve(
               command: "cat",
               surface_kind: :static_ssh,
               target_id: "ssh-target-1",
               transport_options: %{destination: "ssh.example"}
             )

    assert {:ok, leased_ssh} =
             ExecutionSurface.resolve(
               command: "cat",
               surface_kind: :leased_ssh,
               lease_ref: "lease-1",
               surface_ref: "surface-1",
               transport_options: %{destination: "leased.example"}
             )

    assert static_ssh.surface.surface_kind == :static_ssh
    assert static_ssh.adapter_options[:target_id] == "ssh-target-1"
    assert static_ssh.adapter_options[:destination] == "ssh.example"

    assert leased_ssh.surface.surface_kind == :leased_ssh
    assert leased_ssh.adapter_options[:lease_ref] == "lease-1"
    assert leased_ssh.adapter_options[:surface_ref] == "surface-1"
    assert leased_ssh.adapter_options[:destination] == "leased.example"
  end

  test "rejects guest bridge before adapter startup" do
    assert {:error, {:unsupported_surface_kind, :guest_bridge}} =
             ExecutionSurface.resolve(command: "cat", surface_kind: :guest_bridge)
  end
end
