defmodule CliSubprocessCore.RecoveryEnvelope do
  @moduledoc """
  Normalized recoverability facts for provider and transport failures.

  The core owns the provider/transport/runtime semantics. Downstream runtimes
  can consume this envelope to decide whether to retry, resume, repair, or fail
  terminally without re-encoding provider-specific heuristics.
  """

  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderCLI.ErrorRuntimeFailure
  alias ExecutionPlane.Process.Transport.Error, as: TransportError

  @type t :: %{
          optional(String.t()) => boolean() | integer() | String.t() | map()
        }

  @spec from_runtime_failure(ErrorRuntimeFailure.t()) :: t()
  def from_runtime_failure(%ErrorRuntimeFailure{} = failure) do
    case failure.kind do
      :cli_not_found ->
        base_envelope("local_runtime", "cli_missing",
          retryable?: false,
          repairable?: false,
          resumeable?: false,
          local_deterministic?: true,
          remote_claim?: false,
          severity: "error",
          phase: "startup",
          provider_code: "cli_not_found"
        )

      :cwd_not_found ->
        base_envelope("local_runtime", "cwd_missing",
          retryable?: false,
          repairable?: false,
          resumeable?: false,
          local_deterministic?: true,
          remote_claim?: false,
          severity: "error",
          phase: "startup",
          provider_code: "config_invalid"
        )

      :auth_error ->
        base_envelope("remote_provider", "provider_auth_claim",
          retryable?: true,
          repairable?: true,
          resumeable?: false,
          local_deterministic?: false,
          remote_claim?: true,
          suggested_delay_ms: 1_500,
          suggested_max_attempts: 3,
          severity: "fatal",
          phase: "stream",
          provider_code: "auth_error"
        )

      :process_exit ->
        base_envelope("remote_provider", "provider_runtime_claim",
          retryable?: true,
          repairable?: true,
          resumeable?: false,
          local_deterministic?: false,
          remote_claim?: true,
          suggested_delay_ms: 1_500,
          suggested_max_attempts: 3,
          severity: "error",
          phase: "stream",
          provider_code: "runtime_error"
        )

      :transport_error ->
        base_envelope("transport", "transport_disconnect",
          retryable?: true,
          repairable?: true,
          resumeable?: true,
          local_deterministic?: false,
          remote_claim?: false,
          suggested_delay_ms: 1_000,
          suggested_max_attempts: 4,
          severity: "error",
          phase: "transport",
          provider_code: "transport_error"
        )
    end
  end

  @spec from_transport_error(TransportError.t()) :: t()
  def from_transport_error(%TransportError{} = error) do
    transport_error_envelope(error.reason)
  end

  @spec from_payload_error(atom(), Payload.Error.t(), map()) :: t()
  def from_payload_error(provider, %Payload.Error{} = payload, metadata \\ %{})
      when is_atom(provider) and is_map(metadata) do
    existing = metadata["recovery"] || metadata[:recovery]

    if is_map(existing) and map_size(existing) > 0 do
      stringify_map(existing)
    else
      classify_payload_error(provider, payload)
    end
  end

  defp classify_payload_error(_provider, %Payload.Error{code: code, severity: severity}) do
    code
    |> normalize_code()
    |> payload_error_envelope(severity)
  end

  defp transport_error_envelope({:command_not_found, _command}), do: cli_missing_envelope()
  defp transport_error_envelope({:cwd_not_found, _cwd}), do: cwd_missing_envelope()

  defp transport_error_envelope({:invalid_options, _reason}),
    do: transport_invalid_options_envelope()

  defp transport_error_envelope({:unsupported_capability, _capability, _surface_kind}),
    do: transport_unsupported_envelope()

  defp transport_error_envelope({:buffer_overflow, _actual, _max}), do: buffer_overflow_envelope()
  defp transport_error_envelope({:bridge_protocol_error, _reason}), do: protocol_error_envelope()

  defp transport_error_envelope({:bridge_remote_error, _code, _details}),
    do: provider_runtime_transport_envelope()

  defp transport_error_envelope(:timeout), do: transport_timeout_envelope()

  defp transport_error_envelope(reason)
       when reason in [:not_connected, :transport_stopped] do
    transport_disconnect_envelope()
  end

  defp transport_error_envelope({:call_exit, _reason}), do: transport_disconnect_envelope()
  defp transport_error_envelope({:send_failed, _reason}), do: transport_disconnect_envelope()
  defp transport_error_envelope({:startup_failed, _reason}), do: startup_failed_envelope()
  defp transport_error_envelope(_other), do: transport_error_envelope()

  defp payload_error_envelope("auth_error", severity),
    do: remote_claim_envelope("provider_auth_claim", severity, "auth_error")

  defp payload_error_envelope("config_invalid", severity),
    do: remote_claim_envelope("provider_config_claim", severity, "config_invalid")

  defp payload_error_envelope("rate_limit", severity),
    do:
      remote_claim_envelope("provider_rate_limit", severity, "rate_limit",
        suggested_delay_ms: 2_000,
        suggested_max_attempts: 5
      )

  defp payload_error_envelope("timeout", severity),
    do: transport_timeout_envelope(severity)

  defp payload_error_envelope("transport_error", severity),
    do: transport_disconnect_envelope(severity)

  defp payload_error_envelope("user_cancelled", severity),
    do: remote_terminal_envelope("user_cancelled", severity)

  defp payload_error_envelope("approval_denied", severity),
    do: remote_terminal_envelope("approval_denied", severity)

  defp payload_error_envelope("guardrail_blocked", severity),
    do: remote_terminal_envelope("guardrail_blocked", severity)

  defp payload_error_envelope(code, severity),
    do: remote_claim_envelope("provider_runtime_claim", severity, code)

  defp cli_missing_envelope do
    base_envelope("local_runtime", "cli_missing",
      retryable?: false,
      repairable?: false,
      resumeable?: false,
      local_deterministic?: true,
      remote_claim?: false,
      severity: "error",
      phase: "startup",
      provider_code: "cli_not_found"
    )
  end

  defp cwd_missing_envelope do
    base_envelope("local_runtime", "cwd_missing",
      retryable?: false,
      repairable?: false,
      resumeable?: false,
      local_deterministic?: true,
      remote_claim?: false,
      severity: "error",
      phase: "startup",
      provider_code: "config_invalid"
    )
  end

  defp transport_invalid_options_envelope do
    base_envelope("local_runtime", "transport_invalid_options",
      retryable?: false,
      repairable?: false,
      resumeable?: false,
      local_deterministic?: true,
      remote_claim?: false,
      severity: "error",
      phase: "startup",
      provider_code: "config_invalid"
    )
  end

  defp transport_unsupported_envelope do
    base_envelope("local_runtime", "transport_unsupported",
      retryable?: false,
      repairable?: false,
      resumeable?: false,
      local_deterministic?: true,
      remote_claim?: false,
      severity: "error",
      phase: "startup",
      provider_code: "config_invalid"
    )
  end

  defp buffer_overflow_envelope do
    base_envelope("transport", "buffer_overflow",
      retryable?: false,
      repairable?: false,
      resumeable?: false,
      local_deterministic?: true,
      remote_claim?: false,
      severity: "fatal",
      phase: "transport",
      provider_code: "buffer_overflow"
    )
  end

  defp protocol_error_envelope do
    base_envelope("protocol", "protocol_error",
      retryable?: true,
      repairable?: true,
      resumeable?: true,
      local_deterministic?: false,
      remote_claim?: false,
      suggested_delay_ms: 1_000,
      suggested_max_attempts: 4,
      severity: "error",
      phase: "transport",
      provider_code: "transport_error"
    )
  end

  defp provider_runtime_transport_envelope do
    remote_claim_envelope("provider_runtime_claim", "error", "runtime_error", phase: "transport")
  end

  defp transport_timeout_envelope(severity \\ "error") do
    base_envelope("transport", "transport_timeout",
      retryable?: true,
      repairable?: true,
      resumeable?: true,
      local_deterministic?: false,
      remote_claim?: false,
      suggested_delay_ms: 1_000,
      suggested_max_attempts: 4,
      severity: severity_label(severity),
      phase: "transport",
      provider_code: "timeout"
    )
  end

  defp transport_disconnect_envelope(severity \\ "error") do
    base_envelope("transport", "transport_disconnect",
      retryable?: true,
      repairable?: true,
      resumeable?: true,
      local_deterministic?: false,
      remote_claim?: false,
      suggested_delay_ms: 1_000,
      suggested_max_attempts: 4,
      severity: severity_label(severity),
      phase: "transport",
      provider_code: "transport_error"
    )
  end

  defp startup_failed_envelope do
    base_envelope("local_runtime", "startup_failed",
      retryable?: true,
      repairable?: false,
      resumeable?: false,
      local_deterministic?: false,
      remote_claim?: false,
      suggested_delay_ms: 1_000,
      suggested_max_attempts: 3,
      severity: "error",
      phase: "startup",
      provider_code: "transport_error"
    )
  end

  defp transport_error_envelope do
    base_envelope("transport", "transport_error",
      retryable?: true,
      repairable?: true,
      resumeable?: true,
      local_deterministic?: false,
      remote_claim?: false,
      suggested_delay_ms: 1_000,
      suggested_max_attempts: 4,
      severity: "error",
      phase: "transport",
      provider_code: "transport_error"
    )
  end

  defp remote_claim_envelope(class, severity, provider_code, opts \\ []) do
    base_envelope("remote_provider", class,
      retryable?: true,
      repairable?: true,
      resumeable?: false,
      local_deterministic?: false,
      remote_claim?: true,
      suggested_delay_ms: Keyword.get(opts, :suggested_delay_ms, 1_500),
      suggested_max_attempts: Keyword.get(opts, :suggested_max_attempts, 3),
      severity: severity_label(severity),
      phase: Keyword.get(opts, :phase, "stream"),
      provider_code: provider_code
    )
  end

  defp remote_terminal_envelope(class, severity) do
    base_envelope("remote_provider", class,
      retryable?: false,
      repairable?: false,
      resumeable?: false,
      local_deterministic?: false,
      remote_claim?: true,
      severity: severity_label(severity),
      phase: "stream",
      provider_code: class
    )
  end

  defp base_envelope(origin, class, attrs) do
    %{
      "origin" => origin,
      "class" => class,
      "retryable?" => Keyword.fetch!(attrs, :retryable?),
      "repairable?" => Keyword.fetch!(attrs, :repairable?),
      "resumeable?" => Keyword.fetch!(attrs, :resumeable?),
      "local_deterministic?" => Keyword.fetch!(attrs, :local_deterministic?),
      "remote_claim?" => Keyword.fetch!(attrs, :remote_claim?),
      "severity" => Keyword.get(attrs, :severity, "error"),
      "phase" => Keyword.get(attrs, :phase, "stream"),
      "provider_code" => Keyword.get(attrs, :provider_code, "unknown")
    }
    |> maybe_put("suggested_delay_ms", Keyword.get(attrs, :suggested_delay_ms))
    |> maybe_put("suggested_max_attempts", Keyword.get(attrs, :suggested_max_attempts))
  end

  defp severity_label(value) when value in [:fatal, "fatal"], do: "fatal"
  defp severity_label(value) when value in [:warning, "warning"], do: "warning"
  defp severity_label(_value), do: "error"

  defp normalize_code(nil), do: "unknown"

  defp normalize_code(code) when is_atom(code) do
    code
    |> Atom.to_string()
    |> normalize_code()
  end

  defp normalize_code(code) when is_binary(code) do
    code
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> "unknown"
      normalized -> normalized
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
