defmodule CliSubprocessCore.TransportInfoTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.TransportInfo
  alias ExecutionPlane.Process.Transport.Info, as: RuntimeTransportInfo

  describe "facade helpers" do
    test "projects transport info snapshots" do
      info = RuntimeTransportInfo.disconnected()

      assert TransportInfo.match?(info)
      assert TransportInfo.status(info) == :disconnected
      assert TransportInfo.surface_kind(info) == :local_subprocess
      assert TransportInfo.stderr(info) == ""
      assert TransportInfo.pid(info) == nil
      assert TransportInfo.os_pid(info) == nil
      assert TransportInfo.to_map(info).status == :disconnected
      refute Map.has_key?(TransportInfo.to_map(info), :pid)
      refute Map.has_key?(TransportInfo.to_map(info), :os_pid)
    end

    test "also sanitizes core transport maps" do
      pid = self()
      info = %{status: :connected, surface_kind: :ssh_exec, stderr: "tail", pid: pid, os_pid: 123}

      assert TransportInfo.match?(info)
      assert TransportInfo.status(info) == :connected
      assert TransportInfo.surface_kind(info) == :ssh_exec
      assert TransportInfo.stderr(info) == "tail"
      assert TransportInfo.pid(info) == nil
      assert TransportInfo.os_pid(info) == nil

      assert TransportInfo.to_map(info) == %{
               status: :connected,
               surface_kind: :ssh_exec,
               stderr: "tail"
             }
    end
  end
end
