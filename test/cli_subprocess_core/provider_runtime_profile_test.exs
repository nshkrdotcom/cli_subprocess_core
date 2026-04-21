defmodule CliSubprocessCore.ProviderRuntimeProfileTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.{Command, Payload, Session}
  alias CliSubprocessCore.Command.RunResult

  @config_key :provider_runtime_profiles
  @session_event_tag :cli_subprocess_core_session

  setup do
    previous = Application.get_env(:cli_subprocess_core, @config_key)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:cli_subprocess_core, @config_key)
        value -> Application.put_env(:cli_subprocess_core, @config_key, value)
      end
    end)

    Application.delete_env(:cli_subprocess_core, @config_key)
    :ok
  end

  test "configured runtime profiles replay provider-native session output through normal parsers" do
    profiles =
      Map.new(provider_cases(), fn {provider, scenario_ref, line, _content} ->
        {provider,
         [
           scenario_ref: scenario_ref,
           stdout_frames: [line],
           exit: :normal,
           observability: %{packet: :phase5prelim}
         ]}
      end)

    Application.put_env(:cli_subprocess_core, @config_key, profiles: profiles)

    Enum.each(provider_cases(), fn {provider, scenario_ref, _line, content} ->
      ref = make_ref()

      assert {:ok, session, info} =
               Session.start_session(
                 provider: provider,
                 prompt: "provider prompt is not used for simulation selection",
                 subscriber: {self(), ref}
               )

      assert info.invocation.command == "cli-subprocess-core-lower-simulation-#{provider}"
      assert info.transport.info.surface_kind == :lower_simulation
      assert info.transport.info.adapter_metadata.lower_simulation?
      assert info.transport.info.adapter_metadata.scenario_ref == scenario_ref
      assert info.transport.info.adapter_metadata.side_effect_policy == "deny_process_spawn"
      assert info.transport.info.observability.packet == :phase5prelim
      assert info.transport.info.observability.provider_runtime_profile?

      run_started = receive_session_event(ref, &(&1.kind == :run_started))
      assert %Payload.RunStarted{command: command} = run_started.payload
      assert command == "cli-subprocess-core-lower-simulation-#{provider}"

      assistant_delta = receive_session_event(ref, &(&1.kind == :assistant_delta))
      assert assistant_delta.provider == provider
      assert %Payload.AssistantDelta{content: ^content} = assistant_delta.payload

      monitor = Process.monitor(session)
      assert_receive {:DOWN, ^monitor, :process, ^session, reason}, 2_000
      assert reason in [:normal, :noproc]
    end)
  end

  test "provider-aware Command.run uses the configured lower simulation transport" do
    Application.put_env(:cli_subprocess_core, @config_key,
      profiles: %{
        codex: [
          scenario_ref: "phase5prelim://cli/codex-command",
          stdout: ~s({"type":"response.output_text.delta","delta":"codex command"}\n),
          stderr: "diagnostic\n",
          exit_code: 0
        ]
      }
    )

    assert {:ok, %RunResult{} = result} =
             Command.run(provider: :codex, prompt: "run one-shot through runtime profile")

    assert result.invocation.command == "cli-subprocess-core-lower-simulation-codex"
    assert result.stdout == ~s({"type":"response.output_text.delta","delta":"codex command"}\n)
    assert result.stderr == "diagnostic\n"
    assert result.exit.status == :success
  end

  test "required runtime profiles fail closed before provider CLI resolution or spawn" do
    Application.put_env(:cli_subprocess_core, @config_key, required?: true, profiles: %{})

    assert {:error, {:provider_runtime_profile_required, :claude}} =
             Session.start_session(provider: :claude, prompt: "must not resolve a real CLI")
  end

  test "invalid runtime profiles fail closed before provider CLI resolution or spawn" do
    Application.put_env(:cli_subprocess_core, @config_key,
      profiles: %{claude: [stdout_frames: [~s({"type":"assistant_delta","delta":"ignored"}\n)]]}
    )

    assert {:error,
            {:invalid_provider_runtime_profile, :claude,
             {:missing_required_option, :scenario_ref, :claude}}} =
             Session.start_session(provider: :claude, prompt: "must not resolve a real CLI")
  end

  defp provider_cases do
    [
      {:claude, "phase5prelim://cli/claude",
       ~s({"type":"assistant_delta","delta":"claude wire","session_id":"claude-sim"}\n),
       "claude wire"},
      {:codex, "phase5prelim://cli/codex",
       ~s({"type":"response.output_text.delta","delta":"codex wire","session_id":"codex-sim"}\n),
       "codex wire"},
      {:gemini, "phase5prelim://cli/gemini",
       ~s({"type":"message","role":"assistant","delta":true,"content":"gemini wire","session_id":"gemini-sim"}\n),
       "gemini wire"},
      {:amp, "phase5prelim://cli/amp",
       ~s({"type":"message_streamed","delta":"amp wire","session_id":"amp-sim"}\n), "amp wire"}
    ]
  end

  defp receive_session_event(ref, predicate)
       when is_reference(ref) and is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + 2_000
    do_receive_session_event(ref, predicate, deadline_ms)
  end

  defp do_receive_session_event(ref, predicate, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {@session_event_tag, ^ref, {:event, event}} ->
        if predicate.(event) do
          event
        else
          do_receive_session_event(ref, predicate, deadline_ms)
        end
    after
      remaining_ms ->
        flunk("timed out waiting for matching session event")
    end
  end
end
