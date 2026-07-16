defmodule CliSubprocessCore.RuntimeGatewayTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.RuntimeGateway.{Error, Session, StartRequest, Status}

  @digest "sha256:" <> String.duplicate("e", 64)

  defp start_attrs do
    %{
      contract_version: 1,
      session_ref: "session://asm/codex/run-1/generation-1",
      generation: 1,
      command_ref: "command://cli-core/codex/run-1",
      command_digest: @digest,
      working_directory_ref: "workspace://synapse/run-1",
      environment_materialization_ref: "materialization://jido/codex/run-1",
      authority_ref: "grant://citadel/codex/run-1",
      target_ref: "target://nshkr/local-process",
      operation_ref: "operation://jido/codex/session-turn",
      deadline_at: ~U[2026-07-15 12:05:00Z],
      fence: 9
    }
  end

  test "start request contains only refs, digest, deadline, generation, and fence" do
    assert {:ok, request} = StartRequest.new(start_attrs())
    assert request.command_digest == @digest

    assert {:error, :invalid_runtime_gateway_start_request} =
             start_attrs()
             |> Map.put(:env, %{"CODEX_API_KEY" => "sentinel-secret"})
             |> StartRequest.new()

    assert {:error, :invalid_runtime_gateway_start_request} =
             start_attrs()
             |> Map.put(:working_directory_ref, "/tmp/ambient-workspace")
             |> StartRequest.new()
  end

  test "session identity is opaque and callback contract is exact" do
    assert {:ok, session} =
             Session.new(
               session_ref: "session://asm/codex/run-1/generation-1",
               generation: 1,
               execution_ref: "execution://cli-core/codex/run-1",
               state: :running,
               fence: 9
             )

    refute is_pid(session.session_ref)

    callbacks = CliSubprocessCore.RuntimeGateway.behaviour_info(:callbacks) |> MapSet.new()

    assert callbacks ==
             MapSet.new([
               {:start_session, 1},
               {:send_input, 2},
               {:end_input, 1},
               {:info, 1},
               {:subscribe, 2},
               {:cancel, 2},
               {:terminate, 2}
             ])
  end

  test "terminal status requires closed streams and a receipt" do
    attrs = %{
      session_ref: "session://asm/codex/run-1/generation-1",
      generation: 1,
      state: :cancelled,
      sequence: 4,
      input_open: false,
      output_open: false,
      receipt_ref: "receipt://cli-core/codex/run-1/cancel",
      exit_status: nil,
      error_ref: nil
    }

    assert {:ok, status} = Status.new(attrs)
    assert status.state == "cancelled"

    assert {:error, :invalid_runtime_gateway_status} =
             attrs |> Map.put(:input_open, true) |> Status.new()

    assert {:error, :invalid_runtime_gateway_status} =
             attrs |> Map.put(:receipt_ref, nil) |> Status.new()
  end

  test "errors are bounded and cannot carry secret fields or false ambiguity" do
    assert {:ok, error} =
             Error.new(
               category: :ambiguous,
               reason_code: "provider_outcome_unknown",
               retryable: false,
               ambiguous: true,
               evidence_ref: "evidence://cli-core/codex/run-1"
             )

    assert error.category == "ambiguous"

    assert {:error, :invalid_runtime_gateway_error} =
             Error.new(
               category: :timeout,
               reason_code: "provider_timeout",
               retryable: true,
               ambiguous: true
             )

    assert {:error, :invalid_runtime_gateway_error} =
             Error.new(
               category: :terminal,
               reason_code: "auth_failed",
               retryable: false,
               ambiguous: false,
               token: "sentinel-secret"
             )
  end
end
