defmodule CliSubprocessCore.TransportInfo do
  @moduledoc """
  Facade helpers for transport metadata snapshots returned by core-owned lanes.

  This module lets product SDKs inspect transport status and IO contracts
  without importing lower runtime modules.
  """

  alias ExecutionPlane.Process.Transport.Info, as: RuntimeTransportInfo

  @opaque t :: RuntimeTransportInfo.t()
  @public_keys [
    :surface_kind,
    :target_id,
    :lease_ref,
    :surface_ref,
    :boundary_class,
    :observability,
    :adapter_capabilities,
    :effective_capabilities,
    :bridge_profile,
    :protocol_version,
    :extensions,
    :adapter_metadata,
    :status,
    :stdout_mode,
    :stdin_mode,
    :pty?,
    :interrupt_mode,
    :stderr,
    :delivery
  ]

  @doc """
  Returns true when `term` is the transport-info representation used by the core.
  """
  @spec match?(term()) :: boolean()
  def match?(%RuntimeTransportInfo{}), do: true

  def match?(%{status: status, surface_kind: surface_kind})
      when status in [:connected, :disconnected, :error] and is_atom(surface_kind),
      do: true

  def match?(_term), do: false

  @doc """
  Returns the transport status, or `nil` when unavailable.
  """
  @spec status(term()) :: :connected | :disconnected | :error | nil
  def status(%RuntimeTransportInfo{status: status}), do: status
  def status(%{status: status}), do: status
  def status(_term), do: nil

  @doc """
  Returns the execution-surface kind, or `nil` when unavailable.
  """
  @spec surface_kind(term()) :: atom() | nil
  def surface_kind(%RuntimeTransportInfo{surface_kind: surface_kind}), do: surface_kind
  def surface_kind(%{surface_kind: surface_kind}), do: surface_kind
  def surface_kind(_term), do: nil

  @doc """
  Returns the retained stderr snapshot, or an empty string when unavailable.
  """
  @spec stderr(term()) :: String.t()
  def stderr(%RuntimeTransportInfo{stderr: stderr}) when is_binary(stderr), do: stderr
  def stderr(%{stderr: stderr}) when is_binary(stderr), do: stderr
  def stderr(_term), do: ""

  @doc """
  Transport owner pids are not part of the public core metadata contract.
  """
  @spec pid(term()) :: nil
  def pid(_term), do: nil

  @doc """
  OS process pids are not part of the public core metadata contract.
  """
  @spec os_pid(term()) :: nil
  def os_pid(_term), do: nil

  @doc """
  Projects transport metadata to a public map without lower runtime handles.

  Raw transport pids, OS pids, ports, and process-owned invocation details stay
  behind the lower runtime boundary. Callers that need observability should use
  the stable surface/status/capability fields returned here.
  """
  @spec to_map(term()) :: map()
  def to_map(%RuntimeTransportInfo{} = info), do: info |> Map.from_struct() |> public_map()
  def to_map(%{} = info), do: public_map(info)
  def to_map(_term), do: %{}

  defp public_map(info) when is_map(info) do
    info
    |> Map.take(@public_keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
