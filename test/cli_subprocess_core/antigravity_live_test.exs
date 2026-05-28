defmodule CliSubprocessCore.AntigravityLiveTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.Session

  @moduletag :live
  @moduletag :antigravity

  test "real agy emits plain text through the built-in Antigravity profile" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_antigravity_live_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    ref = make_ref()

    assert {:ok, session, info} =
             Session.start_session(
               provider: :antigravity,
               prompt: "Reply with exactly: ANTIGRAVITY_OK",
               cwd: tmp_dir,
               add_dirs: [tmp_dir],
               dangerously_skip_permissions: true,
               subscriber: {self(), ref},
               headless_timeout_ms: 120_000
             )

    assert info.provider == :antigravity

    events = collect_until_result(ref, [], System.monotonic_time(:millisecond) + 120_000)

    assert Enum.any?(events, fn
             %{kind: :assistant_delta, payload: %Payload.AssistantDelta{content: content}} ->
               String.contains?(content, "ANTIGRAVITY_OK")

             _event ->
               false
           end)

    assert :ok = Session.close(session)
  end

  defp collect_until_result(ref, events, deadline_ms) do
    timeout = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {_tag, ^ref, {:event, event}} ->
        next_events = events ++ [event]

        if event.kind == :result do
          next_events
        else
          collect_until_result(ref, next_events, deadline_ms)
        end
    after
      timeout ->
        flunk("timed out waiting for antigravity live result")
    end
  end
end
