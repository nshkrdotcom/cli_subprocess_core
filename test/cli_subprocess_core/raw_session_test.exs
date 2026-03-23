defmodule CliSubprocessCore.RawSessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CliSubprocessCore.RawSession
  alias CliSubprocessCore.Transport.RunResult

  defmodule TagDriftTransport do
    alias CliSubprocessCore.Transport.Delivery
    alias CliSubprocessCore.Transport.Info

    def start(opts), do: Agent.start(fn -> build_state(opts) end)
    def start_link(opts), do: Agent.start_link(fn -> build_state(opts) end)
    def send(_transport, _data), do: :ok
    def end_input(_transport), do: :ok
    def interrupt(_transport), do: :ok
    def stderr(_transport), do: ""

    def close(transport) do
      Agent.stop(transport, :normal)
      :ok
    catch
      :exit, _reason -> :ok
    end

    def force_close(transport), do: close(transport)

    def status(transport) when is_pid(transport) do
      if Process.alive?(transport), do: :connected, else: :disconnected
    end

    def info(transport) when is_pid(transport) do
      if Process.alive?(transport) do
        Agent.get(transport, fn %{tagged_event_tag: tagged_event_tag} ->
          %Info{
            status: :connected,
            stdout_mode: :raw,
            stdin_mode: :raw,
            pty?: false,
            interrupt_mode: :signal,
            delivery: Delivery.new(tagged_event_tag)
          }
        end)
      else
        Info.disconnected()
      end
    end

    defp build_state(opts) do
      %{
        tagged_event_tag: Keyword.get(opts, :actual_event_tag, :transport_owned_raw_session)
      }
    end
  end

  test "raw sessions preserve exact stdin bytes and collect a normalized result" do
    script = create_test_script("cat")

    assert {:ok, session} = RawSession.start(script, [], stdin?: true, startup_mode: :lazy)

    assert session.receiver == self()
    assert session.stdout_mode == :raw
    assert session.stdin_mode == :raw
    assert session.pty? == false
    assert is_reference(session.transport_ref)
    assert :connected == RawSession.status(session)
    assert RawSession.delivery_info(session).receiver == self()
    assert RawSession.delivery_info(session).transport_ref == session.transport_ref
    assert RawSession.delivery_info(session).tagged_event_tag == session.event_tag

    assert :ok = RawSession.send_input(session, "alpha")
    assert :ok = RawSession.close_input(session)

    assert {:ok, %RunResult{} = result} = RawSession.collect(session, 2_000)
    assert result.stdout == "alpha"
    assert result.output == "alpha"
    assert result.stderr == ""
    assert result.exit.code == 0
    assert RunResult.success?(result)
  end

  test "PTY raw sessions retain PTY metadata and can be force-closed" do
    script = create_test_script("sleep 60")

    assert {:ok, session} =
             RawSession.start(script, [],
               pty?: true,
               interrupt_mode: {:stdin, <<3>>}
             )

    assert session.pty? == true

    assert %{
             delivery: %{tagged_event_tag: :cli_subprocess_core_raw_session},
             transport: %{pty?: true, interrupt_mode: {:stdin, <<3>>}}
           } = RawSession.info(session)

    transport = session.transport
    monitor = Process.monitor(transport)

    assert :ok = RawSession.force_close(session)
    assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}, 2_000
  end

  test "raw session delivery metadata reflects the transport's effective tagged event atom" do
    assert {:ok, session} =
             RawSession.start("ignored", [],
               transport_module: TagDriftTransport,
               event_tag: :requested_raw_session_tag,
               actual_event_tag: :transport_owned_raw_session
             )

    assert session.event_tag == :transport_owned_raw_session
    assert RawSession.delivery_info(session).tagged_event_tag == :transport_owned_raw_session

    assert %{delivery: %{tagged_event_tag: :transport_owned_raw_session}} =
             RawSession.info(session)

    assert :ok = RawSession.stop(session)
  end

  test "lazy startup surfaces subprocess spawn failures before returning a raw session" do
    missing_cwd =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_raw_session_missing_#{System.unique_integer([:positive])}"
      )

    script = create_test_script("cat")

    assert capture_log(fn ->
             assert {:error,
                     {:transport,
                      %CliSubprocessCore.Transport.Error{reason: {:cwd_not_found, ^missing_cwd}}}} =
                      RawSession.start(script, [], startup_mode: :lazy, cwd: missing_cwd)
           end) == ""
  end

  defp create_test_script(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_raw_session_#{System.unique_integer([:positive])}"
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
