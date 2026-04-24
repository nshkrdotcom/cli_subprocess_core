defmodule CliSubprocessCore.TransportInfo do
  @moduledoc """
  Facade helpers for transport metadata snapshots returned by core-owned lanes.

  This module lets product SDKs inspect transport status and IO contracts
  without importing lower runtime modules.
  """

  alias ExecutionPlane.Process.Transport.Info, as: RuntimeTransportInfo

  @opaque t :: RuntimeTransportInfo.t()

  @doc """
  Returns true when `term` is the transport-info representation used by the core.
  """
  @spec match?(term()) :: boolean()
  def match?(%RuntimeTransportInfo{}), do: true
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
  Returns the transport owner pid, when present.
  """
  @spec pid(term()) :: pid() | nil
  def pid(%RuntimeTransportInfo{pid: pid}), do: pid
  def pid(%{pid: pid}), do: pid
  def pid(_term), do: nil

  @doc """
  Returns the OS process pid, when present.
  """
  @spec os_pid(term()) :: pos_integer() | nil
  def os_pid(%RuntimeTransportInfo{os_pid: os_pid}), do: os_pid
  def os_pid(%{os_pid: os_pid}), do: os_pid
  def os_pid(_term), do: nil

  @doc """
  Projects transport metadata to a map without exposing the lower module name.
  """
  @spec to_map(term()) :: map()
  def to_map(%RuntimeTransportInfo{} = info), do: Map.from_struct(info)
  def to_map(%{} = info), do: info
  def to_map(_term), do: %{}
end
