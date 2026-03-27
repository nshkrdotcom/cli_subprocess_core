defmodule CliSubprocessCore.TransportTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.ProcessExit
  alias CliSubprocessCore.Transport
  alias CliSubprocessCore.Transport.Error

  test "start resolves the local adapter from generic execution-surface input" do
    ref = make_ref()
    script = create_test_script("cat")

    assert {:ok, transport} =
             Transport.start(
               command: script,
               subscriber: {self(), ref},
               target_id: "target-1",
               lease_ref: "lease-1",
               surface_ref: "surface-1",
               boundary_class: :local,
               observability: %{suite: :phase_b},
               transport_options: [
                 startup_mode: :lazy,
                 stdout_mode: :raw,
                 stdin_mode: :raw
               ]
             )

    assert %Transport.Info{} = info = Transport.info(transport)
    assert info.surface_kind == :local_subprocess
    assert info.target_id == "target-1"
    assert info.lease_ref == "lease-1"
    assert info.surface_ref == "surface-1"
    assert info.boundary_class == :local
    assert info.observability == %{suite: :phase_b}
    assert info.stdout_mode == :raw
    assert info.stdin_mode == :raw

    assert :ok = Transport.send(transport, "alpha")
    assert :ok = Transport.end_input(transport)

    assert_receive {:cli_subprocess_core, ^ref, {:data, "alpha"}}, 2_000

    assert_receive {:cli_subprocess_core, ^ref, {:exit, %ProcessExit{status: :success, code: 0}}},
                   2_000
  end

  test "start rejects guest bridge until the deferred adapter lands" do
    assert {:error, {:transport, %Error{} = error}} =
             Transport.start(command: "cat", surface_kind: :guest_bridge)

    assert error.reason == {:unsupported_surface_kind, :guest_bridge}
  end

  defp create_test_script(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_transport_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    path = Path.join(dir, "fixture.sh")

    File.write!(path, """
    #!/usr/bin/env bash
    set -euo pipefail
    #{body}
    """)

    File.chmod!(path, 0o755)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    path
  end
end
