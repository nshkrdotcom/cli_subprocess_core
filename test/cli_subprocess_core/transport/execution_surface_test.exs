defmodule CliSubprocessCore.Transport.ExecutionSurfaceTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Transport
  alias CliSubprocessCore.Transport.ExecutionSurface
  alias CliSubprocessCore.Transport.LocalSubprocess

  test "resolves the default local execution surface and normalizes the transport_options lane" do
    assert {:ok, resolved} =
             ExecutionSurface.resolve(
               command: "cat",
               target_id: "target-1",
               transport_options: %{startup_mode: :lazy, stdout_mode: :raw}
             )

    assert resolved.adapter == LocalSubprocess
    assert resolved.surface.surface_kind == :local_subprocess
    assert resolved.surface.target_id == "target-1"
    assert resolved.adapter_options[:command] == "cat"
    assert resolved.adapter_options[:startup_mode] == :lazy
    assert resolved.adapter_options[:stdout_mode] == :raw
    assert resolved.adapter_options[:target_id] == "target-1"
  end

  test "adapter modules resolved by the surface layer satisfy the transport contract" do
    assert {:ok, %{adapter: adapter}} = ExecutionSurface.resolve(command: "cat")

    Enum.each(Transport.behaviour_info(:callbacks), fn {name, arity} ->
      assert function_exported?(adapter, name, arity),
             "#{inspect(adapter)} is missing #{name}/#{arity}"
    end)
  end

  test "rejects unsupported surface kinds before adapter startup" do
    assert {:error, {:unsupported_surface_kind, :leased_ssh}} =
             ExecutionSurface.resolve(command: "cat", surface_kind: :leased_ssh)
  end
end
