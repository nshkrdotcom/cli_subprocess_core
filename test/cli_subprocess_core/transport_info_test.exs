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
    end

    test "also handles core transport maps" do
      pid = self()
      info = %{status: :connected, surface_kind: :ssh_exec, stderr: "tail", pid: pid, os_pid: 123}

      refute TransportInfo.match?(info)
      assert TransportInfo.status(info) == :connected
      assert TransportInfo.surface_kind(info) == :ssh_exec
      assert TransportInfo.stderr(info) == "tail"
      assert TransportInfo.pid(info) == pid
      assert TransportInfo.os_pid(info) == 123
      assert TransportInfo.to_map(info) == info
    end
  end
end
