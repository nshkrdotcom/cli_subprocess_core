defmodule CliSubprocessCore.RuntimeClientGatewayTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Event
  alias CliSubprocessCore.GovernedAuthority
  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfiles.Codex

  alias CliSubprocessCore.RuntimeGateway.{
    Error,
    Local,
    RuntimeClient,
    Session,
    StartRequest,
    Status
  }

  alias ExecutionPlane.ActiveExecution
  alias ExecutionPlane.Admission.Request, as: AdmissionRequest
  alias ExecutionPlane.Authority.Ref, as: AuthorityRef
  alias ExecutionPlane.ExecutionRef
  alias ExecutionPlane.ExecutionResult
  alias ExecutionPlane.Family.ProcessRequest
  alias ExecutionPlane.Placement.Surface
  alias ExecutionPlane.Provenance
  alias ExecutionPlane.Runtime.Error, as: RuntimeError
  alias ExecutionPlane.Runtime.Status, as: RuntimeStatus
  alias ExecutionPlane.Sandbox.AcceptableAttestation
  alias ExecutionPlane.Sandbox.Profile, as: SandboxProfile

  defmodule RuntimeProfile do
    @behaviour CliSubprocessCore.ProviderProfile

    @impl true
    def id, do: :runtime_client_gateway_test

    @impl true
    def capabilities, do: [:interrupt, :streaming]

    @impl true
    def build_invocation(opts) do
      authority = Keyword.fetch!(opts, :governed_authority)
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:runtime_profile_build, authority.command_ref})

      invocation =
        Command.new(
          authority.command,
          ["-c", "while IFS= read -r line; do printf '%s\\n' \"$line\"; done"],
          cwd: authority.cwd,
          env: authority.env,
          clear_env?: true
        )

      teardown = fn ->
        send(test_pid, {:runtime_profile_teardown, authority.command_ref})
      end

      {:ok, invocation, teardown}
    end

    @impl true
    def init_parser_state(_opts), do: %{chunks: 0}

    @impl true
    def decode_stdout(data, state) do
      event =
        Event.new(:assistant_delta,
          provider: id(),
          payload: Payload.AssistantDelta.new(content: data)
        )

      {[event], Map.update!(state, :chunks, &(&1 + 1))}
    end

    @impl true
    def decode_stderr(data, state) do
      event =
        Event.new(:stderr,
          provider: id(),
          payload: Payload.Stderr.new(content: data)
        )

      {[event], Map.update!(state, :chunks, &(&1 + 1))}
    end

    @impl true
    def handle_exit(reason, state) do
      exit =
        if match?(%ExecutionPlane.ProcessExit{}, reason),
          do: reason,
          else: ExecutionPlane.ProcessExit.from_reason(reason)

      event =
        Event.new(:result,
          provider: id(),
          payload:
            Payload.Result.new(
              status:
                if(ExecutionPlane.ProcessExit.successful?(exit),
                  do: :completed,
                  else: :failed
                ),
              stop_reason: exit.reason,
              output: %{code: exit.code, signal: exit.signal}
            )
        )

      {[event], state}
    end

    @impl true
    def transport_options(_opts), do: [startup_mode: :eager]
  end

  defmodule FakeRuntimeClient.State do
    @moduledoc false
  end

  defmodule FakeRuntimeClient do
    @behaviour ExecutionPlane.Runtime.Client

    alias CliSubprocessCore.RuntimeClientGatewayTest.FakeRuntimeClient.State
    alias ExecutionPlane.ActiveExecution
    alias ExecutionPlane.ExecutionRef
    alias ExecutionPlane.ExecutionResult
    alias ExecutionPlane.Runtime.Error
    alias ExecutionPlane.Runtime.Event
    alias ExecutionPlane.Runtime.Status

    def start_state! do
      Agent.start_link(
        fn -> %{calls: [], cleaned: MapSet.new(), executions: %{}} end,
        name: State
      )
    end

    def calls, do: Agent.get(State, &Enum.reverse(&1.calls))
    def cleaned?(ref), do: Agent.get(State, &MapSet.member?(&1.cleaned, ref))

    @impl true
    def start(request, opts) do
      binding = request.metadata["cli_subprocess_core"]
      execution_ref = "execution://runtime-client/#{token(binding["session_ref"])}"

      active =
        ActiveExecution.new!(%{
          execution_ref: execution_ref,
          session_ref: binding["session_ref"],
          admission_decision_ref: "admission://runtime-client/#{request.request_id}",
          node_id: "node://runtime-client/fake",
          lane_id: "process",
          state: "accepted",
          started_at: DateTime.utc_now(),
          fence: binding["fence"]
        })

      update(fn state ->
        execution = %{
          input_open: true,
          output_open: true,
          sequence: 0,
          state: "accepted",
          subscriber: nil
        }

        %{
          state
          | calls: [{:start, request, opts} | state.calls],
            executions: Map.put(state.executions, execution_ref, execution)
        }
      end)

      notify(opts, {:fake_runtime_start, request, active})
      {:ok, active}
    end

    @impl true
    def subscribe(%ExecutionRef{ref: ref}, subscriber, opts) do
      event =
        update_execution(ref, fn execution ->
          event = event(ref, execution.sequence + 1, "started", %{"family" => "process"})

          {%{execution | subscriber: subscriber, sequence: event.sequence, state: "running"},
           event}
        end)

      record({:subscribe, ref, subscriber, opts})
      send(subscriber, {:execution_plane_runtime, ref, event})
      :ok
    end

    @impl true
    def send_input(%ExecutionRef{ref: ref}, input, opts) do
      data = input |> IO.iodata_to_binary() |> String.trim_trailing("\n")

      {subscriber, event} =
        update_execution(ref, fn execution ->
          event =
            event(ref, execution.sequence + 1, "output", %{
              "family" => "process",
              "stream" => "stdout",
              "data" => data
            })

          {%{execution | sequence: event.sequence}, {execution.subscriber, event}}
        end)

      record({:send_input, ref, data, opts})
      send(subscriber, {:execution_plane_runtime, ref, event})
      :ok
    end

    @impl true
    def end_input(%ExecutionRef{ref: ref}, opts) do
      {subscriber, events} =
        finish(ref, "completed", "succeeded", fn execution ->
          input_closed =
            event(ref, execution.sequence + 1, "input_closed", %{"family" => "process"})

          receipt =
            receipt_event(
              ref,
              execution.sequence + 2,
              "completed",
              "succeeded",
              "receipt://runtime-client/#{token(ref)}/completed"
            )

          [input_closed, receipt]
        end)

      record({:end_input, ref, opts})
      Enum.each(events, &send(subscriber, {:execution_plane_runtime, ref, &1}))
      :ok
    end

    @impl true
    def status(%ExecutionRef{ref: ref}, opts) do
      record({:status, ref, opts})

      case Agent.get(State, &Map.fetch(&1.executions, ref)) do
        {:ok, execution} ->
          {:ok,
           RuntimeStatus.new!(%{
             execution_ref: ref,
             state: execution.state,
             sequence: execution.sequence,
             input_open: execution.input_open,
             output_open: execution.output_open
           })}

        :error ->
          {:error,
           Error.new!(
             category: :terminal,
             message: "execution cleaned",
             retryable: false,
             ambiguous: false
           )}
      end
    end

    @impl true
    def cancel(%ExecutionRef{ref: ref}, opts) do
      {subscriber, [receipt]} =
        finish(ref, "cancelled", "cancelled", fn execution ->
          [
            receipt_event(
              ref,
              execution.sequence + 1,
              "cancelled",
              "cancelled",
              "receipt://runtime-client/#{token(ref)}/cancelled"
            )
          ]
        end)

      record({:cancel, ref, opts})
      send(subscriber, {:execution_plane_runtime, ref, receipt})
      :ok
    end

    defp finish(ref, terminal_state, result_status, events_fun) do
      Agent.get_and_update(State, fn state ->
        execution = Map.fetch!(state.executions, ref)
        events = events_fun.(execution)

        next_state = %{
          state
          | calls: [{:finish, ref, terminal_state, result_status} | state.calls],
            cleaned: MapSet.put(state.cleaned, ref),
            executions: Map.delete(state.executions, ref)
        }

        {{execution.subscriber, events}, next_state}
      end)
    end

    defp update_execution(ref, fun) do
      Agent.get_and_update(State, fn state ->
        execution = Map.fetch!(state.executions, ref)
        {execution, result} = fun.(execution)
        {result, %{state | executions: Map.put(state.executions, ref, execution)}}
      end)
    end

    defp record(call), do: update(&%{&1 | calls: [call | &1.calls]})

    defp update(fun), do: Agent.update(State, fun)

    defp notify(opts, message) do
      case Keyword.get(opts, :test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _missing -> :ok
      end
    end

    defp event(ref, sequence, kind, payload) do
      Event.new!(%{
        execution_ref: ref,
        sequence: sequence,
        kind: kind,
        emitted_at: DateTime.utc_now(),
        payload: payload
      })
    end

    defp receipt_event(ref, sequence, terminal_state, result_status, receipt_ref) do
      execution_result =
        ExecutionResult.new!(
          execution_ref: ref,
          status: result_status,
          output: %{"family" => "process", "terminal_state" => terminal_state}
        )

      event(ref, sequence, "receipt", %{
        "receipt_ref" => receipt_ref,
        "terminal_state" => terminal_state,
        "execution_result" => execution_result
      })
    end

    defp token(value) do
      :crypto.hash(:sha256, value)
      |> Base.url_encode64(padding: false)
    end
  end

  defmodule UnavailableRuntimeClient do
    @behaviour ExecutionPlane.Runtime.Client

    @impl true
    def start(request, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:unavailable_runtime_start, request})

      {:error,
       RuntimeError.new!(
         category: :unavailable,
         message: "runtime node unavailable",
         retryable: true,
         ambiguous: false
       )}
    end

    @impl true
    def subscribe(_ref, _subscriber, _opts), do: {:error, :unavailable}

    @impl true
    def send_input(_ref, _input, _opts), do: {:error, :unavailable}

    @impl true
    def end_input(_ref, _opts), do: {:error, :unavailable}

    @impl true
    def status(_ref, _opts), do: {:error, :unavailable}

    @impl true
    def cancel(_ref, _opts), do: {:error, :unavailable}
  end

  setup do
    {:ok, state_pid} = FakeRuntimeClient.start_state!()

    on_exit(fn ->
      if Process.alive?(state_pid), do: Agent.stop(state_pid)
    end)

    :ok
  end

  test "local and runtime modes preserve stream, EOF, terminal status, and opaque identity" do
    {local_request, local_authority, local_opts} = launch("local-equivalence")
    assert :local == Local.execution_mode()
    assert :ok = Local.bind_start(local_request, local_opts)
    assert {:ok, %Session{} = local_session} = Local.start_session(local_request)
    assert :ok = Local.subscribe(local_session, self())
    assert :ok = Local.send_input(local_session, "equivalent-line\n")

    assert_receive {event_tag, %Session{},
                    %Event{
                      kind: :assistant_delta,
                      payload: %Payload.AssistantDelta{content: "equivalent-line"}
                    }},
                   5_000

    assert event_tag == Local.event_message_tag()
    assert :ok = Local.end_input(local_session)
    local_terminal = await_terminal(local_session.session_ref)
    assert local_terminal.state == "completed"
    local_command_ref = local_authority.command_ref
    assert_receive {:runtime_profile_teardown, ^local_command_ref}, 5_000

    {runtime_request, runtime_authority, runtime_opts} = launch("runtime-equivalence")
    assert :runtime_client == RuntimeClient.execution_mode()

    assert :ok =
             bind_runtime(runtime_request, runtime_opts, admission(runtime_request),
               runtime_client: FakeRuntimeClient
             )

    runtime_command_ref = runtime_authority.command_ref
    assert_receive {:runtime_profile_build, ^runtime_command_ref}
    refute_receive {:runtime_profile_build, ^runtime_command_ref}, 20

    assert {:ok, %Session{} = runtime_session} = RuntimeClient.start_session(runtime_request)
    refute is_pid(runtime_session.execution_ref)
    assert String.starts_with?(runtime_session.execution_ref, "execution://")

    assert_receive {:fake_runtime_start, %AdmissionRequest{} = admitted, %ActiveExecution{}}
    assert %ProcessRequest{} = process_request = admitted.payload
    assert process_request.command_ref == runtime_request.command_ref
    assert process_request.working_directory_ref == runtime_request.working_directory_ref

    assert process_request.environment_materialization_ref ==
             runtime_request.environment_materialization_ref

    refute Map.has_key?(Map.from_struct(process_request), :env)
    refute Map.has_key?(Map.from_struct(process_request), :cwd)

    assert :ok = RuntimeClient.subscribe(runtime_session, self())
    assert :ok = RuntimeClient.send_input(runtime_session, "equivalent-line\n")

    assert_receive {event_tag, %Session{},
                    %Event{
                      kind: :assistant_delta,
                      payload: %Payload.AssistantDelta{content: "equivalent-line"}
                    }},
                   5_000

    assert event_tag == RuntimeClient.event_message_tag()
    assert {:ok, %Status{state: "running"}} = RuntimeClient.info(runtime_session)
    assert :ok = RuntimeClient.end_input(runtime_session)

    runtime_terminal = await_terminal(runtime_session.session_ref)
    assert runtime_terminal.state == local_terminal.state
    assert runtime_terminal.exit_status == local_terminal.exit_status
    assert runtime_terminal.input_open == local_terminal.input_open
    assert runtime_terminal.output_open == local_terminal.output_open

    assert_receive {:runtime_profile_teardown, ^runtime_command_ref}, 5_000
    assert FakeRuntimeClient.cleaned?(runtime_session.execution_ref)
    assert {:ok, ^runtime_terminal} = RuntimeClient.info(runtime_session)
  end

  test "runtime sessions isolate opaque identity and preserve incremental ordering" do
    {request_one, _authority_one, opts_one} = launch("isolation-one")
    {request_two, _authority_two, opts_two} = launch("isolation-two")

    assert :ok = bind_runtime(request_one, opts_one, admission(request_one))
    assert :ok = bind_runtime(request_two, opts_two, admission(request_two))
    assert {:ok, session_one} = RuntimeClient.start_session(request_one)
    assert {:ok, session_two} = RuntimeClient.start_session(request_two)
    assert session_one.execution_ref != session_two.execution_ref
    assert :ok = RuntimeClient.subscribe(session_one, self())
    assert :ok = RuntimeClient.subscribe(session_two, self())

    assert :ok = RuntimeClient.send_input(session_one, "first")
    assert :ok = RuntimeClient.send_input(session_one, "second")

    assert_receive {_, %Session{session_ref: session_ref},
                    %Event{
                      kind: :assistant_delta,
                      sequence: first_sequence,
                      payload: %Payload.AssistantDelta{content: "first"}
                    }},
                   5_000

    assert session_ref == session_one.session_ref

    assert_receive {_, %Session{session_ref: ^session_ref},
                    %Event{
                      kind: :assistant_delta,
                      sequence: second_sequence,
                      payload: %Payload.AssistantDelta{content: "second"}
                    }},
                   5_000

    assert second_sequence > first_sequence

    forged = %{session_one | execution_ref: session_two.execution_ref}

    assert {:error, %Error{reason_code: "session_identity_mismatch"}} =
             RuntimeClient.send_input(forged, "must-not-cross")

    refute Enum.any?(FakeRuntimeClient.calls(), fn
             {:send_input, ref, "must-not-cross", _opts} ->
               ref in [session_one.execution_ref, session_two.execution_ref]

             _call ->
               false
           end)

    assert :ok = RuntimeClient.cancel(session_one, :test_cleanup)
    assert :ok = RuntimeClient.cancel(session_two, :test_cleanup)
    assert %Status{state: "cancelled"} = await_terminal(session_one.session_ref)
    assert %Status{state: "cancelled"} = await_terminal(session_two.session_ref)
  end

  test "runtime binding derives the same exact Codex resume argv as the shared profile" do
    {request, _authority, session_opts} = launch("codex-resume")
    prompt = "continue through runtime; no shell"
    resume_target = "codex-thread-123"

    session_opts =
      session_opts
      |> Keyword.put(:provider, :codex)
      |> Keyword.put(:profile, Codex)
      |> Keyword.put(:prompt, prompt)
      |> Keyword.put(:resume, resume_target)
      |> Keyword.delete(:test_pid)

    assert :ok = bind_runtime(request, session_opts, admission(request))
    assert {:ok, session} = RuntimeClient.start_session(request)

    assert_receive {:fake_runtime_start,
                    %AdmissionRequest{
                      payload: %ProcessRequest{
                        arguments: [
                          "exec",
                          "resume",
                          "--json",
                          ^resume_target,
                          ^prompt
                        ]
                      }
                    }, %ActiveExecution{}}

    assert :ok = RuntimeClient.subscribe(session, self())
    assert :ok = RuntimeClient.cancel(session, :test_cleanup)
    assert %Status{state: "cancelled"} = await_terminal(session.session_ref)
  end

  test "cancel and terminate reach the same lower cancellation with distinct CLI terminals" do
    {cancel_request, _authority, cancel_opts} = launch("cancel")
    {terminate_request, _authority, terminate_opts} = launch("terminate")

    assert :ok = bind_runtime(cancel_request, cancel_opts, admission(cancel_request))
    assert :ok = bind_runtime(terminate_request, terminate_opts, admission(terminate_request))
    assert {:ok, cancelled_session} = RuntimeClient.start_session(cancel_request)
    assert {:ok, terminated_session} = RuntimeClient.start_session(terminate_request)
    assert :ok = RuntimeClient.subscribe(cancelled_session, self())
    assert :ok = RuntimeClient.subscribe(terminated_session, self())

    assert :ok = RuntimeClient.cancel(cancelled_session, {:unsafe, "ignored"})

    assert %Status{state: "cancelled", exit_status: 130} =
             await_terminal(cancelled_session.session_ref)

    assert :ok = RuntimeClient.terminate(terminated_session, {:unsafe, "ignored"})

    assert %Status{state: "terminated", exit_status: 143} =
             await_terminal(terminated_session.session_ref)

    cancelled_refs =
      for {:cancel, ref, opts} <- FakeRuntimeClient.calls() do
        assert Keyword.keys(opts) |> Enum.sort() == [:fence, :test_pid]
        ref
      end

    assert Enum.sort(cancelled_refs) ==
             Enum.sort([cancelled_session.execution_ref, terminated_session.execution_ref])
  end

  test "runtime failure never downgrades to local execution" do
    {request, authority, session_opts} = launch("no-downgrade")

    assert :ok =
             bind_runtime(request, session_opts, admission(request),
               runtime_client: UnavailableRuntimeClient
             )

    assert {:error,
            %Error{
              category: "unavailable",
              reason_code: "runtime_start_unavailable",
              retryable: true
            }} = RuntimeClient.start_session(request)

    assert_receive {:unavailable_runtime_start, %AdmissionRequest{}}
    command_ref = authority.command_ref
    assert_receive {:runtime_profile_teardown, ^command_ref}

    {fallback_request, _authority, fallback_opts} = launch("fallback-option")

    assert {:error, %Error{reason_code: "runtime_fallback_forbidden"}} =
             RuntimeClient.bind_start(
               fallback_request,
               runtime_binding(
                 fallback_request,
                 fallback_opts,
                 admission(fallback_request),
                 FakeRuntimeClient
               )
               |> Keyword.update!(:runtime_client_opts, &Keyword.put(&1, :fallback, Local))
             )
  end

  test "binding derives one process request and rejects authority or materialization smuggling" do
    {request, authority, session_opts} = launch("binding")
    supplied_payload = %{"caller_supplied" => true}

    assert {:error, %Error{reason_code: "runtime_payload_must_be_derived"}} =
             bind_runtime(
               request,
               session_opts,
               %{admission(request) | payload: supplied_payload}
             )

    command_ref = authority.command_ref
    assert_receive {:runtime_profile_teardown, ^command_ref}

    {wrong_request, _authority, wrong_opts} = launch("wrong-authority")

    wrong_admission =
      wrong_request
      |> admission()
      |> Map.put(:authority_ref, AuthorityRef.new!(ref: "grant://citadel/wrong"))

    assert {:error, %Error{reason_code: "runtime_authority_mismatch"}} =
             bind_runtime(wrong_request, wrong_opts, wrong_admission)

    {smuggle_request, _authority, smuggle_opts} = launch("smuggle")

    assert {:error, %Error{reason_code: "runtime_materialization_smuggling"}} =
             RuntimeClient.bind_start(
               smuggle_request,
               runtime_binding(
                 smuggle_request,
                 smuggle_opts,
                 admission(smuggle_request),
                 FakeRuntimeClient
               )
               |> Keyword.update!(
                 :runtime_client_opts,
                 &Keyword.put(&1, :environment_materializations, %{
                   smuggle_request.environment_materialization_ref => %{"TOKEN" => "secret"}
                 })
               )
             )
  end

  defp launch(token) do
    authority =
      GovernedAuthority.fetch!(%{
        authority_ref: "grant://citadel/codex/#{token}",
        credential_lease_ref: "lease://jido/codex/#{token}",
        connector_instance_ref: "connector-instance://jido/codex/#{token}",
        connector_binding_ref: "connector-binding://jido/codex/#{token}",
        provider_account_ref: "provider-account://jido/codex/#{token}",
        native_auth_assertion_ref: "native-auth-assertion://jido/codex/#{token}",
        target_ref: "target://nshkr/runtime-process/#{token}",
        operation_policy_ref: "operation-policy://citadel/codex/#{token}",
        materialized_command: "/bin/sh",
        materialized_cwd: System.tmp_dir!(),
        materialized_env: %{"LC_ALL" => "C"},
        clear_env?: true,
        command_ref: "command://cli-core/codex/#{token}"
      })

    request =
      StartRequest.new!(%{
        contract_version: 1,
        session_ref: "session://asm/codex/#{token}/generation-1",
        generation: 1,
        command_ref: authority.command_ref,
        command_digest: RuntimeClient.command_digest(authority),
        working_directory_ref: "workspace://synapse/#{token}",
        environment_materialization_ref: "materialization://jido/codex/#{token}",
        authority_ref: authority.authority_ref,
        target_ref: authority.target_ref,
        operation_ref: "operation://jido/codex/session-turn/#{token}",
        deadline_at: DateTime.add(DateTime.utc_now(), 60, :second),
        fence: System.unique_integer([:positive, :monotonic])
      })

    session_opts = [
      provider: RuntimeProfile.id(),
      profile: RuntimeProfile,
      governed_authority: authority,
      metadata: %{
        working_directory_ref: request.working_directory_ref,
        environment_materialization_ref: request.environment_materialization_ref,
        operation_ref: request.operation_ref
      },
      test_pid: self()
    ]

    {request, authority, session_opts}
  end

  defp admission(request) do
    AdmissionRequest.new!(%{
      request_id: "admission:cli:#{request.generation}:#{request.fence}",
      lane_id: "process",
      operation: "process.start",
      payload: %{},
      authority_ref: AuthorityRef.new!(ref: request.authority_ref),
      sandbox_profile:
        SandboxProfile.new!(
          profile_ref: "sandbox://citadel/cli/#{request.fence}",
          bundle_hash: "sha256:" <> String.duplicate("a", 64),
          opaque_bundle: %{"policy_ref" => request.operation_ref}
        ),
      acceptable_attestation:
        AcceptableAttestation.new!(
          classes: ["runtime.process.test"],
          priority_order: ["runtime.process.test"]
        ),
      placement: Surface.new!(surface_kind: "runtime_client", family: "process"),
      provenance: Provenance.node_admitted(owner: "cli_subprocess_core_test")
    })
  end

  defp bind_runtime(request, session_opts, admission, opts \\ []) do
    RuntimeClient.bind_start(
      request,
      runtime_binding(
        request,
        session_opts,
        admission,
        Keyword.get(opts, :runtime_client, FakeRuntimeClient)
      )
    )
  end

  defp runtime_binding(request, session_opts, admission, runtime_client) do
    [
      admission: admission,
      runtime_client: runtime_client,
      runtime_client_opts: [fence: request.fence, test_pid: self()],
      session_opts: session_opts
    ]
  end

  defp await_terminal(session_ref, attempts \\ 20)

  defp await_terminal(_session_ref, 0), do: flunk("did not receive terminal gateway status")

  defp await_terminal(session_ref, attempts) do
    receive do
      {tag, %Session{session_ref: ^session_ref}, %Status{} = status}
      when tag == :cli_subprocess_core_runtime_gateway_terminal ->
        status

      {_tag, %Session{}, %Event{}} ->
        await_terminal(session_ref, attempts - 1)
    after
      250 ->
        await_terminal(session_ref, attempts - 1)
    end
  end
end
