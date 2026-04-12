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
           }).fact_id == "cli_fact:reconnect:provider-2:2"

    assert LineageFact.subprocess(%{
             provider: :amp,
             provider_session_id: "provider-3",
             subprocess_id: "subprocess-1"
           }).subprocess_id == "subprocess-1"
  end
end
