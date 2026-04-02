defmodule CliSubprocessCore.ChannelTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Channel
  alias CliSubprocessCore.TestSupport
  alias CliSubprocessCore.TestSupport.FakeSSH
  alias ExternalRuntimeTransport.ProcessExit

  test "channel streams local framed IO and exposes stable delivery metadata" do
    ref = make_ref()

    script =
      create_test_script("""
      input="$(cat)"
      printf 'local:%s\\n' "$input"
      """)

    assert {:ok, channel, info} =
             Channel.start_channel(
               command: script,
               subscriber: {self(), ref},
               stdout_mode: :raw,
               stdin_mode: :raw
             )

    assert info.delivery.tagged_event_tag == :cli_subprocess_core_channel
    assert info.transport.stdout_mode == :raw
    assert info.transport.stdin_mode == :raw
    assert info.transport.surface_kind == :local_subprocess
    assert Channel.delivery_info(channel).tagged_event_tag == :cli_subprocess_core_channel
    monitor_ref = Process.monitor(channel)

    assert :ok = Channel.send(channel, "alpha")
    assert :ok = Channel.end_input(channel)

    assert_receive {:cli_subprocess_core_channel, ^ref, {:data, "local:alpha\n"}}, 2_000

    assert {:ok, {:data, "local:alpha\n"}} =
             Channel.extract_event(
               {:cli_subprocess_core_channel, ref, {:data, "local:alpha\n"}},
               ref
             )

    assert_receive {:cli_subprocess_core_channel, ^ref,
                    {:exit, %ProcessExit{status: :success, code: 0}}},
                   2_000

    assert_receive {:DOWN, ^monitor_ref, :process, ^channel, :normal}, 2_000
  end

  test "channel preserves execution-surface metadata and runs over fake SSH" do
    ref = make_ref()
    fake_ssh = FakeSSH.new!()
    on_exit(fn -> FakeSSH.cleanup(fake_ssh) end)

    script =
      create_test_script("""
      input="$(cat)"
      printf 'ssh:%s\\n' "$input"
      """)

    assert {:ok, channel, info} =
             Channel.start_channel(
               command: script,
               subscriber: {self(), ref},
               stdout_mode: :raw,
               stdin_mode: :raw,
               surface_kind: :ssh_exec,
               target_id: "ssh-target-1",
               transport_options:
                 FakeSSH.transport_options(fake_ssh,
                   destination: "channel.test.example",
                   port: 2222
                 )
             )

    assert info.transport.surface_kind == :ssh_exec
    assert info.transport.target_id == "ssh-target-1"
    assert info.transport.adapter_metadata.destination == "channel.test.example"
    assert info.transport.adapter_metadata.port == 2222
    assert info.transport.adapter_metadata.ssh_path == fake_ssh.ssh_path

    assert :ok = Channel.send_input(channel, "beta")
    assert :ok = Channel.close_input(channel)

    assert_receive {:cli_subprocess_core_channel, ^ref, {:data, "ssh:beta\n"}}, 2_000
    assert_receive {:cli_subprocess_core_channel, ^ref, {:exit, %ProcessExit{code: 0}}}, 2_000

    assert FakeSSH.wait_until_written(fake_ssh, 1_000) == :ok

    manifest = FakeSSH.read_manifest!(fake_ssh)
    assert manifest =~ "destination=channel.test.example"
    assert manifest =~ "port=2222"
  end

  defp create_test_script(body) do
    dir = TestSupport.tmp_dir!("cli_subprocess_core_channel")
    on_exit(fn -> File.rm_rf!(dir) end)

    TestSupport.write_executable!(
      dir,
      "fixture.sh",
      """
      #!/usr/bin/env bash
      set -euo pipefail
      #{body}
      """
    )
  end
end
