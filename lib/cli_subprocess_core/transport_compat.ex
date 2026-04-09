defmodule CliSubprocessCore.TransportCompat do
  @moduledoc false

  alias ExecutionPlane.Command, as: RuntimeCommand
  alias ExecutionPlane.Process.Transport.Delivery, as: RuntimeDelivery
  alias ExecutionPlane.Process.Transport.Error, as: RuntimeTransportError
  alias ExecutionPlane.Process.Transport.Info, as: RuntimeInfo
  alias ExecutionPlane.Process.Transport.Surface.Capabilities, as: RuntimeCapabilities
  alias ExecutionPlane.ProcessExit, as: RuntimeProcessExit
  alias ExternalRuntimeTransport.Command, as: TransportCommand
  alias ExternalRuntimeTransport.ExecutionSurface.Capabilities, as: TransportCapabilities
  alias ExternalRuntimeTransport.ProcessExit
  alias ExternalRuntimeTransport.Transport.Delivery
  alias ExternalRuntimeTransport.Transport.Error
  alias ExternalRuntimeTransport.Transport.Info

  @spec to_process_exit(term()) :: ProcessExit.t()
  def to_process_exit(%ProcessExit{} = exit), do: exit

  def to_process_exit(%RuntimeProcessExit{} = exit) do
    %ProcessExit{
      status: exit.status,
      code: exit.code,
      signal: exit.signal,
      reason: exit.reason,
      stderr: exit.stderr
    }
  end

  @spec to_transport_error(term()) :: Error.t() | term()
  def to_transport_error(%Error{} = error), do: error

  def to_transport_error(%RuntimeTransportError{} = error) do
    Error.transport_error(error.reason, Map.new(error.context || %{}))
  end

  def to_transport_error(other), do: other

  @spec to_transport_command(term()) :: TransportCommand.t() | nil
  def to_transport_command(nil), do: nil
  def to_transport_command(%TransportCommand{} = command), do: command

  def to_transport_command(%RuntimeCommand{} = command) do
    TransportCommand.new(command.command, command.args,
      cwd: command.cwd,
      env: command.env,
      clear_env?: command.clear_env?,
      user: command.user
    )
  end

  @spec to_transport_capabilities(term()) :: TransportCapabilities.t() | nil
  def to_transport_capabilities(nil), do: nil
  def to_transport_capabilities(%TransportCapabilities{} = capabilities), do: capabilities

  def to_transport_capabilities(%RuntimeCapabilities{} = capabilities) do
    capabilities
    |> Map.take(TransportCapabilities.keys())
    |> TransportCapabilities.new!()
  end

  @spec to_transport_delivery(term()) :: Delivery.t() | nil
  def to_transport_delivery(nil), do: nil
  def to_transport_delivery(%Delivery{} = delivery), do: delivery

  def to_transport_delivery(%RuntimeDelivery{} = delivery) do
    Delivery.new(delivery.tagged_event_tag)
  end

  @spec to_transport_info(term()) :: Info.t() | nil
  def to_transport_info(nil), do: nil
  def to_transport_info(%Info{} = info), do: info

  def to_transport_info(%RuntimeInfo{} = info) do
    %Info{
      invocation: to_transport_command(info.invocation),
      pid: info.pid,
      os_pid: info.os_pid,
      surface_kind: info.surface_kind,
      target_id: info.target_id,
      lease_ref: info.lease_ref,
      surface_ref: info.surface_ref,
      boundary_class: info.boundary_class,
      observability: info.observability,
      adapter_capabilities: to_transport_capabilities(info.adapter_capabilities),
      effective_capabilities: to_transport_capabilities(info.effective_capabilities),
      bridge_profile: info.bridge_profile,
      protocol_version: info.protocol_version,
      extensions: info.extensions,
      adapter_metadata: info.adapter_metadata,
      status: info.status,
      stdout_mode: info.stdout_mode,
      stdin_mode: info.stdin_mode,
      pty?: info.pty?,
      interrupt_mode: info.interrupt_mode,
      stderr: info.stderr,
      delivery: to_transport_delivery(info.delivery)
    }
  end
end
