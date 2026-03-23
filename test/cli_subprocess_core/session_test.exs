defmodule CliSubprocessCore.SessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfiles.{Amp, Claude, Codex, Gemini}
  alias CliSubprocessCore.Session
  alias CliSubprocessCore.Transport

  @session_event_tag :cli_subprocess_core_session

  describe "first-party provider sessions" do
    test "Claude session emits normalized events from the built-in profile" do
      assert_fixture_session(:claude, Claude, "claude", "solve this", 10)
    end

    test "Codex session emits normalized events from the built-in profile" do
      assert_fixture_session(:codex, Codex, "codex", "review this", 7)
    end

    test "Gemini session emits normalized events from the built-in profile" do
      assert_fixture_session(:gemini, Gemini, "gemini", "hello", 7)
    end

    test "Amp session emits normalized events from the built-in profile" do
      assert_fixture_session(:amp, Amp, "amp", "ship it", 9)
    end
  end

  test "subscribe, unsubscribe, send, and end_input drive the session transport" do
    script =
      create_test_script("""
      while IFS= read -r line; do
        printf '{"type":"assistant_delta","delta":"%s","session_id":"stdin-session"}\\n' "$line"
      done
      sleep 0.2
      printf '{"type":"result","stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}\\n'
      """)

    assert {:ok, session, _info} =
             Session.start_session(
               provider: :claude,
               prompt: "ignored",
               command: script,
               startup_mode: :lazy
             )

    {:links, links} = Process.info(self(), :links)
    refute session in links

    ref = make_ref()

    info = Session.info(session)
    assert %Transport.Info{} = info.transport.info
    assert info.transport.status == :connected
    assert is_pid(info.transport.subprocess_pid)
    assert is_integer(info.transport.os_pid)
    assert info.transport.os_pid > 0
    assert info.transport.stdout_mode == :line
    assert info.transport.stdin_mode == :line
    assert info.transport.pty? == false
    assert info.transport.interrupt_mode == :signal

    assert :ok = Session.subscribe(session, self(), ref)
    assert :ok = Session.send(session, "hello")
    assert :ok = Session.end_input(session)

    assert_receive {@session_event_tag, ^ref, {:event, delta}}, 2_000
    assert delta.kind == :assistant_delta
    assert delta.provider_session_id == "stdin-session"
    assert %Payload.AssistantDelta{content: "hello"} = delta.payload

    assert :ok = Session.unsubscribe(session, self())

    monitor = Process.monitor(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2_000
    refute_receive {@session_event_tag, ^ref, {:event, _event}}, 200
  end

  test "interrupt requests propagate through the session and surface a terminal error" do
    ref = make_ref()

    script =
      create_test_script("""
      trap 'exit 130' INT
      sleep 60
      """)

    assert {:ok, session, _info} =
             Session.start_session(
               provider: :claude,
               prompt: "interrupt me",
               command: script,
               subscriber: {self(), ref}
             )

    assert_receive {@session_event_tag, ^ref, {:event, run_started}}, 2_000
    assert run_started.kind == :run_started

    assert :ok = Session.interrupt(session)

    assert_receive {@session_event_tag, ^ref, {:event, error_event}}, 2_000
    assert error_event.kind == :error
    assert %Payload.Error{message: message} = error_event.payload
    assert message =~ "CLI exited with code"

    monitor = Process.monitor(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, reason}, 2_000
    assert reason in [:normal, :noproc]
  end

  test "stderr-only provider output is normalized before the terminal error" do
    ref = make_ref()

    script =
      create_test_script("""
      printf 'stderr-only chunk' >&2
      exit 42
      """)

    assert {:ok, session, _info} =
             Session.start_session(
               provider: :claude,
               prompt: "stderr only",
               command: script,
               subscriber: {self(), ref}
             )

    assert_receive {@session_event_tag, ^ref, {:event, run_started}}, 2_000
    assert run_started.kind == :run_started

    assert_receive {@session_event_tag, ^ref, {:event, stderr_event}}, 2_000
    assert stderr_event.kind == :stderr
    assert %Payload.Stderr{content: "stderr-only chunk"} = stderr_event.payload

    assert_receive {@session_event_tag, ^ref, {:event, error_event}}, 2_000
    assert error_event.kind == :error
    assert %Payload.Error{message: message} = error_event.payload
    assert message =~ "CLI exited with code 42"

    monitor = Process.monitor(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, reason}, 2_000
    assert reason in [:normal, :noproc]
  end

  test "subscriber churn reuses the existing monitor for the same pid" do
    script = create_test_script("sleep 60")

    assert {:ok, session, _info} =
             Session.start_session(
               provider: :claude,
               prompt: "hold",
               command: script
             )

    first_ref = make_ref()
    second_ref = make_ref()

    assert :ok = Session.subscribe(session, self(), first_ref)
    assert {:monitors, monitors_after_first_subscribe} = Process.info(session, :monitors)
    assert length(monitors_after_first_subscribe) == 1

    assert :ok = Session.subscribe(session, self(), second_ref)
    assert {:monitors, monitors_after_second_subscribe} = Process.info(session, :monitors)
    assert length(monitors_after_second_subscribe) == 1

    state = :sys.get_state(session)
    assert %{tag: ^second_ref} = state.subscribers[self()]

    assert :ok = Session.unsubscribe(session, self())
    assert {:monitors, []} = Process.info(session, :monitors)

    assert :ok = Session.close(session)
  end

  test "lazy transport startup errors return before the session reports run_started" do
    missing_cwd =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_session_missing_#{System.unique_integer([:positive])}"
      )

    ref = make_ref()
    script = create_test_script("printf 'never-runs\\n'")

    assert capture_log(fn ->
             assert {:error,
                     {:transport,
                      %CliSubprocessCore.Transport.Error{reason: {:cwd_not_found, ^missing_cwd}}}} =
                      Session.start_session(
                        provider: :claude,
                        prompt: "missing cwd",
                        command: script,
                        cwd: missing_cwd,
                        startup_mode: :lazy,
                        subscriber: {self(), ref}
                      )
           end) == ""

    refute_receive {@session_event_tag, ^ref, {:event, _event}}, 200
  end

  defp assert_fixture_session(provider, profile, fixture_name, prompt, expected_event_count) do
    ref = make_ref()
    fixture_path = fixture_path(fixture_name)
    script = create_fixture_cli(fixture_path)

    assert {:ok, session, info} =
             Session.start_session(
               provider: provider,
               prompt: prompt,
               command: script,
               subscriber: {self(), ref},
               metadata: %{lane: :core}
             )

    assert info.provider == provider
    assert info.profile == profile
    assert info.invocation.command == script
    assert info.transport.status == :connected
    assert Session.info(session).provider == provider
    assert Session.info(session).profile == profile

    events = receive_session_events(ref, expected_event_count)

    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..expected_event_count)
    assert Enum.all?(events, &(&1.provider == provider))

    [run_started | parsed_events] = events
    assert run_started.kind == :run_started
    assert %Payload.RunStarted{command: ^script} = run_started.payload
    assert run_started.metadata == %{lane: :core}

    assert Enum.any?(parsed_events, &(&1.kind == :result))
    assert Enum.at(parsed_events, 0).provider_session_id == "#{provider}-session-1"

    monitor = Process.monitor(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2_000
  end

  defp receive_session_events(ref, count) when is_integer(count) and count > 0 do
    Enum.map(1..count, fn _index ->
      assert_receive {@session_event_tag, ^ref, {:event, event}}, 2_000
      event
    end)
  end

  defp create_fixture_cli(fixture_path) do
    create_test_script("""
    cat "#{fixture_path}"
    """)
  end

  defp fixture_path(fixture_name) do
    Path.expand("../fixtures/provider_profiles/#{fixture_name}.jsonl", __DIR__)
  end

  defp create_test_script(body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_session_#{System.unique_integer([:positive])}"
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
