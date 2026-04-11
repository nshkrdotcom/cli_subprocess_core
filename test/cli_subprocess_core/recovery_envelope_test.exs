defmodule CliSubprocessCore.RecoveryEnvelopeTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.{Payload, ProviderCLI, RecoveryEnvelope}
  alias ExecutionPlane.Process.Transport.Error, as: TransportError

  test "classifies deterministic local runtime failures as non-retryable" do
    failure = %ProviderCLI.ErrorRuntimeFailure{
      kind: :cli_not_found,
      provider: :codex,
      message: "Codex CLI not found",
      context: %{},
      cause: nil
    }

    assert %{
             "origin" => "local_runtime",
             "class" => "cli_missing",
             "retryable?" => false,
             "local_deterministic?" => true
           } = RecoveryEnvelope.from_runtime_failure(failure)
  end

  test "classifies remote auth claims as retryable remote failures" do
    payload =
      Payload.Error.new(
        message: "Authentication failed",
        code: "auth_error",
        severity: :fatal
      )

    assert %{
             "origin" => "remote_provider",
             "class" => "provider_auth_claim",
             "retryable?" => true,
             "repairable?" => true,
             "suggested_max_attempts" => 3
           } = RecoveryEnvelope.from_payload_error(:claude, payload)
  end

  test "classifies transport disconnects as resumeable" do
    transport_error = TransportError.transport_error(:transport_stopped)

    assert %{
             "origin" => "transport",
             "class" => "transport_disconnect",
             "retryable?" => true,
             "resumeable?" => true,
             "suggested_max_attempts" => 4
           } = RecoveryEnvelope.from_transport_error(transport_error)
  end

  test "classifies rate limits as retryable remote claims with extended budget" do
    payload =
      Payload.Error.new(
        message: "Rate limit exceeded",
        code: "rate_limit",
        severity: :error
      )

    assert %{
             "origin" => "remote_provider",
             "class" => "provider_rate_limit",
             "retryable?" => true,
             "repairable?" => true,
             "suggested_delay_ms" => 2000,
             "suggested_max_attempts" => 5
           } = RecoveryEnvelope.from_payload_error(:codex, payload)
  end

  test "classifies transport timeouts as resumeable" do
    transport_error = TransportError.transport_error(:timeout)

    assert %{
             "origin" => "transport",
             "class" => "transport_timeout",
             "retryable?" => true,
             "resumeable?" => true,
             "suggested_max_attempts" => 4
           } = RecoveryEnvelope.from_transport_error(transport_error)
  end

  test "classifies approval denial as remote terminal failure" do
    payload =
      Payload.Error.new(
        message: "Tool approval denied",
        code: "approval_denied",
        severity: :fatal
      )

    assert %{
             "origin" => "remote_provider",
             "class" => "approval_denied",
             "retryable?" => false,
             "repairable?" => false,
             "remote_claim?" => true
           } = RecoveryEnvelope.from_payload_error(:codex, payload)
  end

  test "classifies startup failures as bounded local startup retries" do
    transport_error = TransportError.transport_error({:startup_failed, :spawn_failed})

    assert %{
             "origin" => "local_runtime",
             "class" => "startup_failed",
             "retryable?" => true,
             "local_deterministic?" => false,
             "suggested_max_attempts" => 3
           } = RecoveryEnvelope.from_transport_error(transport_error)
  end
end
