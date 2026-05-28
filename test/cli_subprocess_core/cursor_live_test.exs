defmodule CliSubprocessCore.CursorLiveTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.Session

  @moduletag :live
  @moduletag :cursor

  test "real Cursor agent emits stream-json through the built-in profile" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "cli_subprocess_core_cursor_live_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    ref = make_ref()

    assert {:ok, session, info} =
             Session.start_session(
               provider: :cursor,
               prompt: "Reply with exactly: CURSOR_OK and do not edit files.",
               cwd: tmp_dir,
               permission_mode: :bypass,
               subscriber: {self(), ref},
               headless_timeout_ms: 120_000
             )

    assert info.provider == :cursor

    events = collect_until_result(ref, [], System.monotonic_time(:millisecond) + 120_000)
    assert Enum.any?(events, &(&1.kind == :assistant_delta or &1.kind == :assistant_message))

    assert Enum.any?(events, fn
             %{kind: :result, payload: %Payload.Result{output: %{result: result}}}
             when is_binary(result) ->
               String.contains?(result, "CURSOR_OK")

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
        flunk("timed out waiting for cursor live result")
    end
  end
end
