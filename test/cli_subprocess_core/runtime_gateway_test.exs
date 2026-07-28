defmodule CliSubprocessCore.RuntimeGatewayTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Event
  alias CliSubprocessCore.GovernedAuthority
  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.RuntimeGateway.Local
  alias CliSubprocessCore.RuntimeGateway.{Error, Session, StartRequest, Status}
  alias ExecutionPlane.ProcessExit

  @digest "sha256:" <> String.duplicate("e", 64)

  defmodule LocalProfile do
    @behaviour CliSubprocessCore.ProviderProfile

    @impl true
    def id, do: :runtime_gateway_local_test

    @impl true
    def capabilities, do: [:interrupt, :streaming]

    @impl true
    def build_invocation(opts) do
      authority = Keyword.fetch!(opts, :governed_authority)

      {:ok,
       Command.new(
         authority.command,
         ["-c", "while IFS= read -r line; do printf '%s\\n' \"$line\"; done"],
         cwd: authority.cwd,
         env: authority.env,
         clear_env?: true
       )}
    end

    @impl true
    def init_parser_state(_opts), do: %{}

    @impl true
    def decode_stdout(data, state) do
      event =
        Event.new(:assistant_delta,
          provider: id(),
          payload: Payload.AssistantDelta.new(content: data)
        )

      {[event], state}
    end

    @impl true
    def decode_stderr(data, state) do
      event =
        Event.new(:stderr, provider: id(), payload: Payload.Stderr.new(content: data))

      {[event], state}
    end

    @impl true
    def handle_exit(reason, state) do
      exit = if match?(%ProcessExit{}, reason), do: reason, else: ProcessExit.from_reason(reason)

      event =
        Event.new(:result,
          provider: id(),
          payload:
            Payload.Result.new(
              status: if(exit.status == :success, do: :completed, else: :failed),
              stop_reason: exit.reason
            )
        )

      {[event], state}
    end

    @impl true
    def transport_options(_opts), do: [startup_mode: :eager]
  end

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

    assert Enum.all?(callbacks, fn {name, arity} ->
             function_exported?(Local, name, arity)
           end)
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

  test "local gateway consumes one exact governed binding and owns the real terminal lifecycle" do
    authority = governed_authority("lifecycle")

    request =
      start_attrs()
      |> Map.merge(%{
        session_ref: "session://asm/codex/runtime-gateway-lifecycle",
        command_ref: authority.command_ref,
        command_digest: Local.command_digest(authority),
        authority_ref: authority.authority_ref,
        target_ref: authority.target_ref,
        deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })
      |> StartRequest.new!()

    session_opts = [
      provider: LocalProfile.id(),
      profile: LocalProfile,
      governed_authority: authority,
      metadata: binding_metadata(request)
    ]

    assert :ok = Local.bind_start(request, session_opts)

    assert {:error, %Error{reason_code: "session_identity_already_claimed"}} =
             Local.bind_start(request, session_opts)

    assert {:ok, %Session{} = session} = Local.start_session(request)
    refute is_pid(session.session_ref)
    assert :ok = Local.subscribe(session, self())
    assert :ok = Local.send_input(session, "reviewed-line\n")

    assert_event(session, :assistant_delta)
    assert :ok = Local.end_input(session)

    session_ref = session.session_ref
    generation = session.generation

    assert_receive {:cli_subprocess_core_runtime_gateway_terminal,
                    %Session{
                      session_ref: ^session_ref,
                      generation: ^generation,
                      state: "completed"
                    }, %Status{} = terminal},
                   5_000

    assert terminal.state == "completed"
    assert terminal.exit_status == 0
    assert terminal.input_open == false
    assert terminal.output_open == false
    assert is_binary(terminal.receipt_ref)
    assert {:ok, ^terminal} = Local.info(session)
  end

  test "local gateway rejects a governed launch whose command digest was not reviewed" do
    authority = governed_authority("digest-mismatch")

    request =
      start_attrs()
      |> Map.merge(%{
        session_ref: "session://asm/codex/runtime-gateway-digest-mismatch",
        command_ref: authority.command_ref,
        authority_ref: authority.authority_ref,
        target_ref: authority.target_ref,
        deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })
      |> StartRequest.new!()

    assert {:error, %Error{reason_code: "command_digest_mismatch"}} =
             Local.bind_start(request,
               provider: LocalProfile.id(),
               profile: LocalProfile,
               governed_authority: authority,
               metadata: binding_metadata(request)
             )
  end

  test "local gateway cancellation interrupts, terminates, and closes the session" do
    authority = governed_authority("cancel")

    request =
      start_attrs()
      |> Map.merge(%{
        session_ref: "session://asm/codex/runtime-gateway-cancel",
        command_ref: authority.command_ref,
        command_digest: Local.command_digest(authority),
        authority_ref: authority.authority_ref,
        target_ref: authority.target_ref,
        deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })
      |> StartRequest.new!()

    assert :ok =
             Local.bind_start(request,
               provider: LocalProfile.id(),
               profile: LocalProfile,
               governed_authority: authority,
               metadata: binding_metadata(request)
             )

    assert {:ok, %Session{} = session} = Local.start_session(request)
    assert :ok = Local.subscribe(session, self())
    assert :ok = Local.cancel(session, :operator_cancelled)

    session_ref = session.session_ref
    generation = session.generation

    assert_receive {:cli_subprocess_core_runtime_gateway_terminal,
                    %Session{
                      session_ref: ^session_ref,
                      generation: ^generation,
                      state: "cancelled"
                    }, %Status{state: "cancelled", exit_status: 130} = terminal},
                   5_000

    assert {:ok, ^terminal} = Local.info(session)

    assert {:error, %Error{reason_code: "session_terminal"}} =
             Local.send_input(session, "must-not-dispatch\n")
  end

  defp governed_authority(token) do
    GovernedAuthority.fetch!(%{
      authority_ref: "grant://citadel/codex/#{token}",
      credential_lease_ref: "lease://jido/codex/#{token}",
      connector_instance_ref: "connector-instance://jido/codex/#{token}",
      connector_binding_ref: "connector-binding://jido/codex/#{token}",
      provider_account_ref: "provider-account://jido/codex/#{token}",
      native_auth_assertion_ref: "native-auth-assertion://jido/codex/#{token}",
      target_ref: "target://nshkr/local-process/#{token}",
      operation_policy_ref: "operation-policy://citadel/codex/#{token}",
      materialized_command: "/bin/sh",
      materialized_cwd: System.tmp_dir!(),
      materialized_env: %{"LC_ALL" => "C"},
      clear_env?: true,
      command_ref: "command://cli-core/codex/#{token}"
    })
  end

  defp binding_metadata(request) do
    %{
      working_directory_ref: request.working_directory_ref,
      environment_materialization_ref: request.environment_materialization_ref,
      operation_ref: request.operation_ref
    }
  end

  defp assert_event(session, kind, attempts \\ 10)

  defp assert_event(_session, kind, 0), do: flunk("did not receive #{kind} gateway event")

  defp assert_event(session, kind, attempts) do
    receive do
      {:cli_subprocess_core_runtime_gateway_event, ^session, %Event{kind: ^kind}} ->
        :ok

      {:cli_subprocess_core_runtime_gateway_event, ^session, %Event{}} ->
        assert_event(session, kind, attempts - 1)
    after
      500 ->
        assert_event(session, kind, attempts - 1)
    end
  end
end
