defmodule CliSubprocessCore.LineageFactTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.LineageFact

  test "exposes stable lineage fact kinds and ids" do
    assert CliSubprocessCore.lineage_fact_kinds() == [:pressure, :reconnect, :subprocess]
    assert LineageFact.fact_id(:pressure, "provider-1", 0) == "cli_fact:pressure:provider-1:0"
  end

  test "normalizes provider pressure, reconnect, and subprocess facts" do
    assert LineageFact.pressure(%{
             provider: :codex,
             provider_session_id: "provider-1",
             lane_session_id: "lane-1",
             reason: :rate_limited,
             observed_at: "2026-04-11T00:00:00Z",
             metadata: %{"queue_depth" => 4}
           }) == %{
             fact_id: "cli_fact:pressure:provider-1:0",
             kind: :pressure,
             provider: :codex,
             provider_session_id: "provider-1",
             lane_session_id: "lane-1",
             subprocess_id: nil,
             reason: :rate_limited,
             observed_at: "2026-04-11T00:00:00Z",
             metadata: %{"queue_depth" => 4}
           }

    assert LineageFact.reconnect(%{
             provider: "claude",
             provider_session_id: "provider-2",
             seq: 2
           }).provider == :claude

    assert LineageFact.subprocess(%{
             provider: :amp,
             provider_session_id: "provider-3",
             subprocess_id: "subprocess-1"
           }).subprocess_id == "subprocess-1"
  end

  test "rejects unknown provider strings without creating atoms" do
    error =
      assert_raise ArgumentError, fn ->
        LineageFact.pressure(%{
          provider: "third-party-profile",
          provider_session_id: "provider-4"
        })
      end

    assert error.message =~ "provider must be one of amp, claude, codex, gemini"
    assert error.message =~ "third-party-profile"
  end
end
