defmodule CliSubprocessCore.Phase6ContractsTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.{
    AdapterSelectionPolicy,
    LowerSimulationScenario,
    ProviderRuntimeProfile
  }

  test "runtime profile declares the CLI lower simulation scenario contract" do
    scenario =
      ProviderRuntimeProfile.lower_simulation_scenario!(
        :codex,
        "lower-scenario://cli-subprocess-core/codex/process"
      )

    dump = LowerSimulationScenario.dump(scenario)

    assert scenario.contract_version == "ExecutionPlane.LowerSimulationScenario.v1"
    assert scenario.scenario_id == "lower-scenario://cli-subprocess-core/codex/process"
    assert scenario.owner_repo == "cli_subprocess_core"
    assert scenario.protocol_surface == "process"
    assert scenario.matcher_class == "deterministic_over_input"
    assert scenario.no_egress_assertion["external_egress"] == "deny"
    assert scenario.no_egress_assertion["process_spawn"] == "deny"

    assert scenario.bounded_evidence_projection["contract_version"] ==
             "ExecutionPlane.LowerSimulationEvidence.v1"

    assert scenario.bounded_evidence_projection["raw_payload_persistence"] == "shape_only"
    assert_json_safe(dump)
    assert LowerSimulationScenario.new!(dump) == scenario
  end

  test "CLI lower scenarios reject bad owner, unsupported enums, egress, and raw evidence" do
    assert_raise ArgumentError, ~r/owner_repo.*cli_subprocess_core/, fn ->
      LowerSimulationScenario.new!(scenario_attrs(%{owner_repo: "execution_plane"}))
    end

    assert_raise ArgumentError, ~r/protocol_surface.*unsupported/, fn ->
      LowerSimulationScenario.new!(scenario_attrs(%{protocol_surface: "http"}))
    end

    assert_raise ArgumentError, ~r/matcher_class.*unsupported/, fn ->
      LowerSimulationScenario.new!(scenario_attrs(%{matcher_class: "semantic_provider"}))
    end

    assert_raise ArgumentError, ~r/semantic provider policy/i, fn ->
      LowerSimulationScenario.new!(Map.put(scenario_attrs(), :provider_refs, ["codex"]))
    end

    assert_raise ArgumentError, ~r/no_egress_assertion.*external_egress.*deny/, fn ->
      LowerSimulationScenario.new!(
        scenario_attrs(%{no_egress_assertion: %{"external_egress" => "allow"}})
      )
    end

    assert_raise ArgumentError, ~r/raw_payload_persistence.*shape_only/, fn ->
      LowerSimulationScenario.new!(
        scenario_attrs(%{
          bounded_evidence_projection: %{
            "contract_version" => "ExecutionPlane.LowerSimulationEvidence.v1",
            "raw_payload_persistence" => "raw_body"
          }
        })
      )
    end

    assert_raise ArgumentError, ~r/ExecutionOutcome.v1.raw_payload.*must not be narrowed/, fn ->
      LowerSimulationScenario.new!(
        scenario_attrs(%{
          bounded_evidence_projection: %{
            "contract_version" => "ExecutionPlane.LowerSimulationEvidence.v1",
            "target_contract" => "ExecutionOutcome.v1.raw_payload",
            "raw_payload_persistence" => "shape_only"
          }
        })
      )
    end
  end

  test "runtime profile declares adapter selection through application config only" do
    policy = ProviderRuntimeProfile.adapter_selection_policy()
    dump = AdapterSelectionPolicy.dump(policy)

    assert policy.contract_version == "ExecutionPlane.AdapterSelectionPolicy.v1"
    assert policy.owner_repo == "cli_subprocess_core"
    assert policy.selection_surface == "application_config"
    assert policy.config_key == "cli_subprocess_core.provider_runtime_profiles"
    assert policy.default_value_when_unset == "normal_provider_cli"
    assert policy.fail_closed_action_when_misconfigured == "reject_required_or_invalid_profile"
    assert_json_safe(dump)
    assert AdapterSelectionPolicy.new!(dump) == policy

    assert_raise ArgumentError, ~r/public simulation selector/i, fn ->
      AdapterSelectionPolicy.new!(Map.put(adapter_policy_attrs(), :simulation, "service_mode"))
    end

    assert_raise ArgumentError, ~r/config_key.*public simulation selector/i, fn ->
      AdapterSelectionPolicy.new!(adapter_policy_attrs(%{config_key: "request.simulation"}))
    end
  end

  test "public request simulation options are rejected before runtime profile selection" do
    assert {:error, {:public_simulation_selector_forbidden, :codex}} =
             ProviderRuntimeProfile.resolve(
               :codex,
               [simulation: :service_mode],
               %CliSubprocessCore.ExecutionSurface{}
             )
  end

  defp scenario_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        scenario_id: "lower-scenario://cli-subprocess-core/codex/process",
        version: "1.0.0",
        owner_repo: "cli_subprocess_core",
        route_kind: "provider_runtime_profile",
        protocol_surface: "process",
        matcher_class: "deterministic_over_input",
        status_or_exit_or_response_or_stream_or_chunk_or_fault_shape: %{
          "exit" => "configured",
          "stream" => "provider_native_stdout_stderr_frames"
        },
        no_egress_assertion: %{
          "external_egress" => "deny",
          "process_spawn" => "deny",
          "side_effect_result" => "not_attempted"
        },
        bounded_evidence_projection: %{
          "contract_version" => "ExecutionPlane.LowerSimulationEvidence.v1",
          "raw_payload_persistence" => "shape_only",
          "fingerprints" => ["input", "stdout_shape", "stderr_shape"]
        },
        input_fingerprint_ref: "fingerprint://cli-subprocess-core/provider-runtime-profile/input",
        cleanup_behavior: %{
          "runtime_artifacts" => "delete",
          "durable_payload" => "deny_raw"
        }
      },
      overrides
    )
  end

  defp adapter_policy_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        selection_surface: "application_config",
        owner_repo: "cli_subprocess_core",
        config_key: "cli_subprocess_core.provider_runtime_profiles",
        default_value_when_unset: "normal_provider_cli",
        fail_closed_action_when_misconfigured: "reject_required_or_invalid_profile"
      },
      overrides
    )
  end

  defp assert_json_safe(value) when is_binary(value) or is_boolean(value) or is_nil(value),
    do: :ok

  defp assert_json_safe(value) when is_integer(value) or is_float(value), do: :ok

  defp assert_json_safe(value) when is_list(value), do: Enum.each(value, &assert_json_safe/1)

  defp assert_json_safe(value) when is_map(value) do
    assert Enum.all?(Map.keys(value), &is_binary/1)
    Enum.each(value, fn {_key, nested} -> assert_json_safe(nested) end)
  end
end
