defmodule CliSubprocessCore.TransportCompatTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.TransportCompat
  alias ExecutionPlane.Command, as: RuntimeCommand
  alias ExecutionPlane.Process.Transport.Delivery, as: RuntimeDelivery
  alias ExecutionPlane.Process.Transport.Error, as: RuntimeTransportError
  alias ExecutionPlane.Process.Transport.Info, as: RuntimeInfo
  alias ExecutionPlane.Process.Transport.Surface.Capabilities, as: RuntimeCapabilities
  alias ExecutionPlane.ProcessExit, as: RuntimeProcessExit
  alias ExternalRuntimeTransport.Command
  alias ExternalRuntimeTransport.ProcessExit
  alias ExternalRuntimeTransport.Transport.Delivery
  alias ExternalRuntimeTransport.Transport.Error
  alias ExternalRuntimeTransport.Transport.Info

  test "projects runtime process exits onto the legacy process-exit type" do
    runtime_exit = %RuntimeProcessExit{status: :signal, signal: :sigterm, reason: :terminated}

    assert %ProcessExit{} = exit = TransportCompat.to_process_exit(runtime_exit)
    assert exit.status == :signal
    assert exit.signal == :sigterm
    assert exit.reason == :terminated
  end

  test "projects runtime transport errors onto the legacy transport error type" do
    runtime_error =
      RuntimeTransportError.unsupported_capability(:run, :test_restricted_spawn)

    assert %Error{} = transport_error = TransportCompat.to_transport_error(runtime_error)
    assert transport_error.reason == {:unsupported_capability, :run, :test_restricted_spawn}
    assert transport_error.context == %{capability: :run, surface_kind: :test_restricted_spawn}
  end

  test "projects runtime transport info onto the legacy info type" do
    runtime_info = %RuntimeInfo{
      invocation: %RuntimeCommand{command: "printf", args: ["ready"]},
      pid: self(),
      os_pid: 123,
      surface_kind: :ssh_exec,
      target_id: "target-1",
      delivery: %RuntimeDelivery{tagged_event_tag: :runtime_tag},
      adapter_capabilities: RuntimeCapabilities.new!(supports_input?: true),
      effective_capabilities: RuntimeCapabilities.new!(supports_input?: true)
    }

    assert %Info{} = info = TransportCompat.to_transport_info(runtime_info)
    assert %Command{} = info.invocation
    assert info.invocation.command == "printf"
    assert info.surface_kind == :ssh_exec
    assert info.target_id == "target-1"
    assert %Delivery{} = info.delivery
    assert info.delivery.tagged_event_tag == :runtime_tag
  end
end
