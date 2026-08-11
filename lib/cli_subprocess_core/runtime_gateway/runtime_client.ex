defmodule CliSubprocessCore.RuntimeGateway.RuntimeClient do
  @moduledoc """
  Runtime-admitted implementation of the CLI process-family gateway.

  A trusted composition injects an `ExecutionPlane.Runtime.Client` and binds
  one secret-free CLI start request to one exact governed admission template.
  The binding is caller-owned, one-shot, and consumed before admission. The
  provider invocation is built exactly once; this gateway derives the
  process-family request from that invocation and owns its teardown.

  Runtime Client events are translated into `CliSubprocessCore.Event` values.
  Public sessions and status values contain opaque references only; node
  addresses, worker identifiers, Runtime Client contracts, and lower process
  details never cross the CLI gateway API.

  This module never falls back to the local gateway. Merely loading it does not
  advertise an observed runtime composition; callers may advertise the runtime
  mode only after a successful admitted start has been observed.
  """

  @behaviour CliSubprocessCore.RuntimeGateway

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Event
  alias CliSubprocessCore.GovernedAuthority
  alias CliSubprocessCore.GovernedSecurity
  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfile
  alias CliSubprocessCore.ProviderRegistry
  alias CliSubprocessCore.RuntimeGateway.CommandBinding
  alias CliSubprocessCore.RuntimeGateway.Error
  alias CliSubprocessCore.RuntimeGateway.Session, as: GatewaySession
  alias CliSubprocessCore.RuntimeGateway.StartRequest
  alias CliSubprocessCore.RuntimeGateway.Status, as: GatewayStatus
  alias CliSubprocessCore.RuntimeGateway.Support
  alias CliSubprocessCore.Session.Options
  alias ExecutionPlane.ActiveExecution
  alias ExecutionPlane.Admission.Request, as: AdmissionRequest
  alias ExecutionPlane.ExecutionResult
  alias ExecutionPlane.Family.ProcessRequest
  alias ExecutionPlane.Runtime.Error, as: RuntimeError
  alias ExecutionPlane.Runtime.Event, as: RuntimeEvent
  alias ExecutionPlane.Runtime.Status, as: RuntimeStatus

  @server __MODULE__
  @event_message :cli_subprocess_core_runtime_gateway_event
  @terminal_message :cli_subprocess_core_runtime_gateway_terminal
  @terminal_retention_ms 60_000
  @gateway_states GatewaySession.states()
  @terminal_states GatewaySession.terminal_states()
  @binding_keys [:admission, :runtime_client, :runtime_client_opts, :session_opts]
  @runtime_callbacks [
    start: 2,
    subscribe: 3,
    send_input: 3,
    end_input: 2,
    status: 2,
    cancel: 2
  ]
  @forbidden_runtime_option_keys [
    :active_options,
    :cwd,
    :env,
    :environment,
    :environment_materializations,
    :working_directories
  ]

  @type bind_error :: Error.t()

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, @server))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Returns the placement mode implemented by this gateway.

  The value identifies selection intent only. It is not proof that a Runtime
  Client node has accepted or observed an execution.
  """
  @spec execution_mode() :: :runtime_client
  def execution_mode, do: :runtime_client

  @doc "Returns the stable tag used for incremental CLI gateway events."
  @spec event_message_tag() :: :cli_subprocess_core_runtime_gateway_event
  def event_message_tag, do: @event_message

  @doc "Returns the stable tag used for terminal CLI gateway status."
  @spec terminal_message_tag() :: :cli_subprocess_core_runtime_gateway_terminal
  def terminal_message_tag, do: @terminal_message

  @doc "Returns the digest required in `StartRequest.command_digest`."
  @spec command_digest(GovernedAuthority.t()) :: String.t()
  defdelegate command_digest(authority), to: CommandBinding, as: :digest

  @doc false
  @spec bind_start(StartRequest.t(), keyword()) :: :ok | {:error, bind_error()}
  def bind_start(%StartRequest{} = request, opts) when is_list(opts) do
    call({:bind_start, request, opts})
  end

  def bind_start(_request, _opts),
    do: {:error, error(:invalid_request, "invalid_runtime_client_binding", false)}

  @impl true
  def start_session(%StartRequest{} = request), do: call({:start_session, request})

  def start_session(_request),
    do: {:error, error(:invalid_request, "invalid_start_request", false)}

  @impl true
  def send_input(%GatewaySession{} = session, input),
    do: call({:send_input, session, input})

  def send_input(_session, _input),
    do: {:error, error(:invalid_request, "invalid_session", false)}

  @impl true
  def end_input(%GatewaySession{} = session), do: call({:end_input, session})

  def end_input(_session),
    do: {:error, error(:invalid_request, "invalid_session", false)}

  @impl true
  def info(%GatewaySession{} = session), do: call({:info, session})

  def info(_session),
    do: {:error, error(:invalid_request, "invalid_session", false)}

  @impl true
  def subscribe(%GatewaySession{} = session, subscriber) when is_pid(subscriber),
    do: call({:subscribe, session, subscriber})

  def subscribe(_session, _subscriber),
    do: {:error, error(:invalid_request, "invalid_subscription", false)}

  @impl true
  def cancel(%GatewaySession{} = session, _reason),
    do: call({:cancel, session, "cancelled"})

  def cancel(_session, _reason),
    do: {:error, error(:invalid_request, "invalid_session", false)}

  @impl true
  def terminate(%GatewaySession{} = session, _reason),
    do: call({:cancel, session, "terminated"})

  def terminate(_reason, %{bindings: bindings, sessions: sessions}) do
    Enum.each(bindings, fn {_key, binding} -> run_teardown(binding) end)
    Enum.each(sessions, fn {_key, entry} -> run_teardown(entry) end)
    :ok
  end

  def terminate(_session, _reason),
    do: {:error, error(:invalid_request, "invalid_session", false)}

  def init(:ok) do
    {:ok,
     %{
       bindings: %{},
       binding_monitors: %{},
       sessions: %{},
       executions: %{}
     }}
  end

  def handle_call({:bind_start, request, opts}, {owner, _tag}, state) do
    key = session_key(request)

    with :ok <- ensure_startable_request(request),
         :ok <- ensure_unclaimed(key, state),
         {:ok, binding} <- build_binding(request, opts) do
      monitor = Process.monitor(owner)
      binding = Map.merge(binding, %{owner: owner, owner_monitor: monitor, request: request})

      {:reply, :ok,
       %{
         state
         | bindings: Map.put(state.bindings, key, binding),
           binding_monitors: Map.put(state.binding_monitors, monitor, key)
       }}
    else
      {:error, %Error{} = gateway_error} ->
        {:reply, {:error, gateway_error}, state}
    end
  end

  def handle_call({:start_session, request}, {owner, _tag}, state) do
    key = session_key(request)

    case Map.fetch(state.bindings, key) do
      {:ok, %{owner: ^owner, request: ^request} = binding} ->
        state = consume_binding(state, key, binding)
        start_bound_session(request, binding, key, state)

      {:ok, %{owner: ^owner}} ->
        {:reply, {:error, error(:unauthorized, "start_request_mismatch", false)}, state}

      {:ok, _other_owner} ->
        {:reply, {:error, error(:unauthorized, "binding_owner_mismatch", false)}, state}

      :error ->
        {:reply, {:error, error(:unauthorized, "runtime_binding_missing", false)}, state}
    end
  end

  def handle_call({:send_input, session, input}, _from, state) do
    with {:ok, entry} <- active_entry(state, session),
         :ok <-
           runtime_reply(
             entry.runtime_client,
             :send_input,
             [entry.execution_ref, input, entry.runtime_client_opts],
             "runtime_send_input"
           ) do
      {:reply, :ok, state}
    else
      {:error, %Error{} = gateway_error} ->
        {:reply, {:error, gateway_error}, state}
    end
  end

  def handle_call({:end_input, session}, _from, state) do
    with {:ok, entry} <- active_entry(state, session),
         :ok <-
           runtime_reply(
             entry.runtime_client,
             :end_input,
             [entry.execution_ref, entry.runtime_client_opts],
             "runtime_end_input"
           ) do
      entry = %{entry | input_open: false}
      {:reply, :ok, put_entry(state, session_key(session), entry)}
    else
      {:error, %Error{} = gateway_error} ->
        {:reply, {:error, gateway_error}, state}
    end
  end

  def handle_call({:info, session}, _from, state) do
    case entry(state, session) do
      {:ok, %{terminal_status: %GatewayStatus{} = status}} ->
        {:reply, {:ok, status}, state}

      {:ok, entry} ->
        with {:ok, %RuntimeStatus{} = runtime_status} <-
               runtime_result(
                 entry.runtime_client,
                 :status,
                 [entry.execution_ref, entry.runtime_client_opts],
                 "runtime_status"
               ),
             {:ok, entry, status} <- project_status(entry, runtime_status) do
          {:reply, {:ok, status}, put_entry(state, session_key(session), entry)}
        else
          {:error, %Error{} = gateway_error} ->
            {:reply, {:error, gateway_error}, state}

          _invalid ->
            {:reply, {:error, error(:transport_lost, "runtime_status_invalid", false)}, state}
        end

      {:error, %Error{} = gateway_error} ->
        {:reply, {:error, gateway_error}, state}
    end
  end

  def handle_call({:subscribe, session, subscriber}, _from, state) do
    case entry(state, session) do
      {:ok, entry} ->
        entry = %{entry | subscribers: MapSet.put(entry.subscribers, subscriber)}
        {:reply, :ok, put_entry(state, session_key(session), entry)}

      {:error, %Error{} = gateway_error} ->
        {:reply, {:error, gateway_error}, state}
    end
  end

  def handle_call({:cancel, session, terminal_override}, _from, state) do
    with {:ok, entry} <- active_entry(state, session),
         :ok <-
           runtime_reply(
             entry.runtime_client,
             :cancel,
             [entry.execution_ref, entry.runtime_client_opts],
             "runtime_cancel"
           ) do
      entry = %{entry | terminal_override: terminal_override}
      {:reply, :ok, put_entry(state, session_key(session), entry)}
    else
      {:error, %Error{} = gateway_error} ->
        {:reply, {:error, gateway_error}, state}
    end
  end

  def handle_info(
        {:execution_plane_runtime, execution_ref, %RuntimeEvent{} = runtime_event},
        state
      )
      when is_binary(execution_ref) do
    case Map.fetch(state.executions, execution_ref) do
      {:ok, key} -> {:noreply, dispatch_runtime_event(state, key, execution_ref, runtime_event)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.binding_monitors, monitor) do
      {:ok, key} ->
        {:noreply, drop_binding_monitor(state, key, monitor)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:forget_terminal, key}, state) do
    case Map.get(state.sessions, key) do
      %{session: %GatewaySession{} = session, execution_ref: execution_ref} = entry ->
        if GatewaySession.terminal?(session) do
          run_teardown(entry)

          {:noreply,
           %{
             state
             | sessions: Map.delete(state.sessions, key),
               executions: Map.delete(state.executions, execution_ref.ref)
           }}
        else
          {:noreply, state}
        end

      _missing ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp build_binding(request, opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in @binding_keys)),
         runtime_client when is_atom(runtime_client) <- Keyword.get(opts, :runtime_client),
         runtime_opts when is_list(runtime_opts) <- Keyword.get(opts, :runtime_client_opts, []),
         true <- Keyword.keyword?(runtime_opts),
         session_opts when is_list(session_opts) <- Keyword.get(opts, :session_opts),
         true <- Keyword.keyword?(session_opts),
         {:ok, options} <- session_options(session_opts),
         {:ok, profile} <- resolve_profile(options),
         :ok <- validate_runtime_client(runtime_client),
         :ok <- validate_runtime_opts(request, runtime_opts),
         :ok <- validate_session_binding(request, options, session_opts),
         {:ok, invocation, teardown} <- build_invocation(profile, options) do
      finish_binding(
        request,
        opts,
        options,
        profile,
        invocation,
        teardown,
        runtime_client,
        runtime_opts
      )
    else
      {:error, %Error{} = gateway_error} ->
        {:error, gateway_error}

      {:error, _reason} ->
        {:error, error(:invalid_request, "invalid_runtime_client_binding", false)}

      _invalid ->
        {:error, error(:invalid_request, "invalid_runtime_client_binding", false)}
    end
  end

  defp finish_binding(
         request,
         opts,
         options,
         profile,
         invocation,
         teardown,
         runtime_client,
         runtime_opts
       ) do
    with {:ok, process_request} <- process_request(request, invocation),
         {:ok, admission} <-
           admission_request(request, Keyword.get(opts, :admission), process_request),
         {:ok, parser_state} <- init_parser(profile, options) do
      {:ok,
       %{
         admission_request: admission,
         authority: options.governed_authority,
         runtime_client: runtime_client,
         runtime_client_opts: runtime_opts,
         profile: profile,
         provider: options.provider,
         parser_state: parser_state,
         teardown: teardown,
         teardown_done?: false
       }}
    else
      {:error, %Error{} = gateway_error} ->
        safe_teardown(teardown)
        {:error, gateway_error}

      _invalid ->
        safe_teardown(teardown)
        {:error, error(:invalid_request, "invalid_runtime_client_binding", false)}
    end
  end

  defp session_options(session_opts) do
    case Options.new(session_opts) do
      {:ok, options} -> {:ok, options}
      {:error, _reason} -> {:error, error(:invalid_request, "session_options_invalid", false)}
    end
  end

  defp resolve_profile(%Options{profile: profile}) when is_atom(profile) and not is_nil(profile),
    do: {:ok, profile}

  defp resolve_profile(%Options{provider: provider, registry: registry}) do
    case ProviderRegistry.fetch(provider, registry) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, error(:invalid_request, "provider_profile_missing", false)}
    end
  catch
    :exit, _reason -> {:error, error(:unavailable, "provider_registry_unavailable", true)}
  end

  defp validate_runtime_client(runtime_client) do
    if Code.ensure_loaded?(runtime_client) and
         Enum.all?(@runtime_callbacks, fn {name, arity} ->
           function_exported?(runtime_client, name, arity)
         end) do
      :ok
    else
      {:error, error(:invalid_request, "runtime_client_invalid", false)}
    end
  end

  defp validate_runtime_opts(request, runtime_opts) do
    cond do
      Keyword.has_key?(runtime_opts, :fallback) ->
        {:error, error(:invalid_request, "runtime_fallback_forbidden", false)}

      Enum.any?(@forbidden_runtime_option_keys, &Keyword.has_key?(runtime_opts, &1)) ->
        {:error, error(:unauthorized, "runtime_materialization_smuggling", false)}

      not is_nil(GovernedSecurity.find_supplementation(runtime_opts)) ->
        {:error, error(:unauthorized, "runtime_materialization_smuggling", false)}

      Keyword.get(runtime_opts, :fence) != request.fence ->
        {:error, error(:unauthorized, "runtime_fence_mismatch", false)}

      true ->
        :ok
    end
  end

  defp validate_session_binding(
         _request,
         %Options{governed_authority: nil},
         _session_opts
       ),
       do: {:error, error(:unauthorized, "governed_authority_required", false)}

  # The refs the authority and the request have to agree on, each with the
  # reason code a mismatch reports. A list rather than a `cond` chain because
  # that is what it is: one comparison per row, and adding a ref should mean
  # adding a row.
  @authority_bindings [
    {:authority_ref, "authority_ref_mismatch"},
    {:target_ref, "target_ref_mismatch"},
    {:command_ref, "command_ref_mismatch"}
  ]

  @metadata_bindings [
    {:working_directory_ref, "working_directory_ref_mismatch"},
    {:environment_materialization_ref, "environment_materialization_ref_mismatch"},
    {:operation_ref, "operation_ref_mismatch"}
  ]

  @lifecycle_keys [:subscriber, :starter, :name]

  defp validate_session_binding(request, %Options{} = options, session_opts) do
    authority = options.governed_authority

    with :ok <- validate_lifecycle_ownership(session_opts),
         :ok <- validate_authority_refs(authority, request),
         :ok <- validate_metadata_refs(options.metadata, request) do
      hold(command_digest(authority) == request.command_digest, "command_digest_mismatch")
    end
  end

  defp validate_lifecycle_ownership(session_opts) do
    if Enum.any?(@lifecycle_keys, &Keyword.has_key?(session_opts, &1)) do
      {:error, error(:invalid_request, "gateway_owns_session_lifecycle", false)}
    else
      :ok
    end
  end

  defp validate_authority_refs(authority, request) do
    Enum.find_value(@authority_bindings, :ok, fn {field, reason} ->
      mismatch(Map.get(authority, field), Map.get(request, field), reason)
    end)
  end

  defp validate_metadata_refs(metadata, request) do
    Enum.find_value(@metadata_bindings, :ok, fn {field, reason} ->
      mismatch(metadata_value(metadata, field), Map.get(request, field), reason)
    end)
  end

  defp mismatch(left, right, reason) do
    if left == right, do: nil, else: {:error, error(:unauthorized, reason, false)}
  end

  defp hold(true, _reason), do: :ok
  defp hold(false, reason), do: {:error, error(:unauthorized, reason, false)}

  defp build_invocation(profile, options) do
    profile_opts = Options.provider_profile_options(options)

    case ProviderProfile.normalize_build_result(profile.build_invocation(profile_opts)) do
      {:ok, %Command{} = invocation, teardown} ->
        case validate_invocation(invocation, options.governed_authority) do
          :ok ->
            {:ok, invocation, teardown}

          {:error, _reason} ->
            safe_teardown(teardown)
            {:error, error(:unauthorized, "governed_invocation_mismatch", false)}
        end

      {:error, _reason} ->
        {:error, error(:invalid_request, "provider_invocation_build_failed", false)}
    end
  rescue
    _error -> {:error, error(:invalid_request, "provider_invocation_build_failed", false)}
  end

  defp validate_invocation(invocation, authority) do
    arguments = invocation.args

    with :ok <- ProviderProfile.validate_invocation(invocation),
         :ok <- GovernedAuthority.enforce_invocation(invocation, authority),
         nil <- GovernedSecurity.find_argv_supplementation(arguments),
         ^arguments <- GovernedSecurity.redact(arguments, authority) do
      :ok
    else
      nil -> {:error, :invalid_governed_invocation}
      _mismatch -> {:error, :unsafe_governed_invocation}
    end
  end

  defp process_request(request, invocation) do
    ProcessRequest.new(%{
      command_ref: request.command_ref,
      executable: invocation.command,
      arguments: invocation.args,
      working_directory_ref: request.working_directory_ref,
      environment_materialization_ref: request.environment_materialization_ref,
      stdin_mode: "pipe",
      deadline_at: request.deadline_at
    })
  end

  defp admission_request(request, template, process_request) do
    with {:ok, attrs} <- admission_attrs(template),
         :ok <- ensure_template_payload_empty(attrs),
         metadata <- attrs |> value(:metadata) |> normalize_metadata(),
         metadata <-
           Map.put(metadata, "cli_subprocess_core", expected_binding_metadata(request)),
         {:ok, %AdmissionRequest{} = admission} <-
           attrs
           |> Map.put(:payload, process_request)
           |> Map.put(:metadata, metadata)
           |> AdmissionRequest.new(),
         :ok <- validate_admission(request, admission, process_request) do
      {:ok, admission}
    else
      {:error, %Error{} = gateway_error} -> {:error, gateway_error}
      _invalid -> {:error, error(:unauthorized, "runtime_admission_template_invalid", false)}
    end
  end

  defp admission_attrs(%AdmissionRequest{} = admission),
    do: {:ok, Map.from_struct(admission)}

  defp admission_attrs(attrs) when is_map(attrs), do: {:ok, attrs}
  defp admission_attrs(attrs) when is_list(attrs), do: {:ok, Map.new(attrs)}
  defp admission_attrs(_attrs), do: :error

  defp ensure_template_payload_empty(attrs) do
    case value(attrs, :payload) do
      nil -> :ok
      payload when payload == %{} -> :ok
      _payload -> {:error, error(:invalid_request, "runtime_payload_must_be_derived", false)}
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp validate_admission(request, admission, process_request) do
    cond do
      admission.lane_id != "process" ->
        {:error, error(:unauthorized, "runtime_lane_mismatch", false)}

      admission.operation != "process.start" ->
        {:error, error(:unauthorized, "runtime_operation_mismatch", false)}

      not governed_admission?(admission) ->
        {:error, error(:unauthorized, "runtime_governance_missing", false)}

      admission.authority_ref.ref != request.authority_ref ->
        {:error, error(:unauthorized, "runtime_authority_mismatch", false)}

      admission.payload != process_request ->
        {:error, error(:unauthorized, "runtime_process_request_mismatch", false)}

      binding_metadata(admission.metadata) != expected_binding_metadata(request) ->
        {:error, error(:unauthorized, "runtime_admission_binding_mismatch", false)}

      true ->
        :ok
    end
  end

  defp governed_admission?(admission) do
    match?(%ExecutionPlane.Authority.Ref{}, admission.authority_ref) and
      match?(%ExecutionPlane.Sandbox.Profile{}, admission.sandbox_profile) and
      match?(%ExecutionPlane.Placement.Surface{}, admission.placement) and
      admission.provenance.kind == "node_admitted"
  end

  defp binding_metadata(metadata) when is_map(metadata) do
    metadata
    |> value(:cli_subprocess_core)
    |> normalize_binding_metadata()
  end

  defp binding_metadata(_metadata), do: %{}

  defp normalize_binding_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, nested} -> {to_string(key), nested} end)
  end

  defp normalize_binding_metadata(_metadata), do: %{}

  defp expected_binding_metadata(request) do
    %{
      "session_ref" => request.session_ref,
      "generation" => request.generation,
      "command_digest" => request.command_digest,
      "operation_ref" => request.operation_ref,
      "target_ref" => request.target_ref,
      "fence" => request.fence
    }
  end

  defp init_parser(profile, options) do
    {:ok, profile.init_parser_state(Options.provider_profile_options(options))}
  rescue
    _error -> {:error, error(:invalid_request, "provider_parser_initialization_failed", false)}
  end

  defp start_bound_session(request, binding, key, state) do
    case ensure_startable_request(request) do
      :ok ->
        do_start_bound_session(request, binding, key, state)

      {:error, %Error{} = gateway_error} ->
        run_teardown(binding)
        {:reply, {:error, gateway_error}, state}
    end
  end

  defp do_start_bound_session(request, binding, key, state) do
    case runtime_result(
           binding.runtime_client,
           :start,
           [binding.admission_request, binding.runtime_client_opts],
           "runtime_start"
         ) do
      {:ok, %ActiveExecution{} = active} ->
        finish_started_session(request, binding, active, key, state)

      {:ok, _invalid} ->
        run_teardown(binding)
        {:reply, {:error, error(:transport_lost, "runtime_start_invalid", false)}, state}

      {:error, %Error{} = gateway_error} ->
        run_teardown(binding)
        {:reply, {:error, gateway_error}, state}
    end
  end

  defp finish_started_session(request, binding, active, key, state) do
    with :ok <- validate_active_execution(request, active),
         :ok <-
           runtime_reply(
             binding.runtime_client,
             :subscribe,
             [active.execution_ref, self(), binding.runtime_client_opts],
             "runtime_subscribe"
           ) do
      session =
        GatewaySession.new!(%{
          session_ref: request.session_ref,
          generation: request.generation,
          execution_ref: active.execution_ref.ref,
          state: active_state(active.state),
          fence: request.fence
        })

      entry =
        binding
        |> Map.drop([:owner, :owner_monitor, :request, :admission_request])
        |> Map.merge(%{
          session: session,
          execution_ref: active.execution_ref,
          runtime_sequence: 0,
          sequence: 0,
          input_open: true,
          output_open: true,
          terminal_override: nil,
          terminal_status: nil,
          subscribers: MapSet.new()
        })

      {:reply, {:ok, session},
       %{
         state
         | sessions: Map.put(state.sessions, key, entry),
           executions: Map.put(state.executions, active.execution_ref.ref, key)
       }}
    else
      {:error, %Error{} = gateway_error} ->
        safe_cancel(binding, active)
        run_teardown(binding)
        {:reply, {:error, gateway_error}, state}
    end
  end

  defp validate_active_execution(request, active) do
    cond do
      active.session_ref != request.session_ref ->
        {:error, error(:unauthorized, "runtime_session_ref_mismatch", false)}

      active.fence != request.fence ->
        {:error, error(:unauthorized, "runtime_fence_mismatch", false)}

      active.lane_id != "process" ->
        {:error, error(:unauthorized, "runtime_lane_mismatch", false)}

      active.state not in ["accepted", "running", "backpressured"] ->
        {:error, error(:transport_lost, "runtime_start_terminal", false)}

      true ->
        :ok
    end
  end

  defp safe_cancel(binding, active) do
    _result =
      safe_runtime_call(
        binding.runtime_client,
        :cancel,
        [active.execution_ref, binding.runtime_client_opts]
      )

    :ok
  end

  defp consume_runtime_event(entry, execution_ref, runtime_event) do
    cond do
      runtime_event.execution_ref.ref != execution_ref ->
        :ignore

      runtime_event.sequence <= entry.runtime_sequence ->
        :ignore

      true ->
        entry = %{entry | runtime_sequence: runtime_event.sequence}
        consume_ordered_runtime_event(entry, runtime_event)
    end
  end

  defp consume_ordered_runtime_event(entry, %RuntimeEvent{kind: "started"} = runtime_event) do
    session = %{entry.session | state: "running"}

    event =
      Event.new(:run_started,
        provider: entry.provider,
        payload:
          Payload.RunStarted.new(
            provider_session_id: entry.session.session_ref,
            metadata: runtime_metadata(entry, runtime_event)
          )
      )

    {entry, events} = normalize_events(%{entry | session: session}, [event], runtime_event)
    {:ok, entry, events, nil}
  end

  defp consume_ordered_runtime_event(
         entry,
         %RuntimeEvent{kind: "output", payload: payload} = runtime_event
       ) do
    case output(payload) do
      {:ok, stream, data} ->
        {events, parser_state} = decode_output(entry.profile, stream, data, entry.parser_state)

        {entry, events} =
          entry
          |> Map.put(:parser_state, parser_state)
          |> normalize_events(events, runtime_event)

        {:ok, entry, events, nil}

      :error ->
        {entry, events} =
          normalize_events(
            entry,
            [
              Event.new(:error,
                provider: entry.provider,
                payload:
                  Payload.Error.new(
                    message: "invalid runtime process output",
                    code: "runtime_output_invalid"
                  )
              )
            ],
            runtime_event
          )

        {:ok, entry, events, nil}
    end
  end

  defp consume_ordered_runtime_event(entry, %RuntimeEvent{kind: "input_closed"}) do
    {:ok, %{entry | input_open: false}, [], nil}
  end

  defp consume_ordered_runtime_event(entry, %RuntimeEvent{kind: "backpressure"}) do
    {:ok, %{entry | session: %{entry.session | state: "backpressured"}}, [], nil}
  end

  defp consume_ordered_runtime_event(
         entry,
         %RuntimeEvent{kind: "status", payload: payload}
       ) do
    state = value(payload, :state)

    if state in ["running", "backpressured"] do
      {:ok, %{entry | session: %{entry.session | state: state}}, [], nil}
    else
      {:ok, entry, [], nil}
    end
  end

  defp consume_ordered_runtime_event(
         entry,
         %RuntimeEvent{kind: "error"} = runtime_event
       ) do
    {entry, events} =
      normalize_events(
        entry,
        [
          Event.new(:error,
            provider: entry.provider,
            payload:
              Payload.Error.new(
                message: "runtime client execution error",
                code: "runtime_client_error"
              )
          )
        ],
        runtime_event
      )

    {:ok, entry, events, nil}
  end

  defp consume_ordered_runtime_event(
         entry,
         %RuntimeEvent{kind: "receipt", payload: payload} = runtime_event
       ) do
    terminal_state = terminal_state(entry, value(payload, :terminal_state))
    receipt_ref = value(payload, :receipt_ref)
    execution_result = value(payload, :execution_result)

    with true <- terminal_state in @terminal_states,
         true <- Support.ref?(receipt_ref),
         true <- match?(%ExecutionResult{}, execution_result) do
      {events, parser_state} =
        terminal_events(
          entry.profile,
          entry.provider,
          terminal_state,
          execution_result,
          entry.parser_state
        )

      session = %{entry.session | state: terminal_state}

      entry =
        entry
        |> Map.merge(%{
          session: session,
          parser_state: parser_state,
          input_open: false,
          output_open: false
        })
        |> run_teardown()

      {entry, events} = normalize_events(entry, events, runtime_event)
      status = terminal_status(entry, receipt_ref, execution_result)
      entry = %{entry | terminal_status: status}
      {:ok, entry, events, status}
    else
      _invalid ->
        {:ok, entry, [], nil}
    end
  end

  defp consume_ordered_runtime_event(entry, _runtime_event), do: {:ok, entry, [], nil}

  defp output(payload) when is_map(payload) do
    case {value(payload, :family), value(payload, :stream), value(payload, :data)} do
      {"process", stream, data} when stream in ["stdout", "stderr"] and is_binary(data) ->
        {:ok, stream, data}

      _invalid ->
        :error
    end
  end

  defp output(_payload), do: :error

  defp decode_output(profile, "stdout", data, parser_state),
    do: safe_profile_call(profile, :decode_stdout, [data, parser_state], parser_state)

  defp decode_output(profile, "stderr", data, parser_state),
    do: safe_profile_call(profile, :decode_stderr, [data, parser_state], parser_state)

  defp terminal_events(profile, provider, state, execution_result, parser_state) do
    reason =
      case state do
        "completed" -> :normal
        "cancelled" -> {:signal, :sigint}
        "terminated" -> {:signal, :sigterm}
        "failed" -> {:exit_status, 1}
        "ambiguous" -> :runtime_outcome_ambiguous
      end

    {events, parser_state} =
      safe_profile_call(profile, :handle_exit, [reason, parser_state], parser_state)

    events =
      events
      |> ensure_terminal_event(provider, state, execution_result)
      |> Enum.map(&decorate_terminal_event(&1, execution_result))

    {events, parser_state}
  end

  defp ensure_terminal_event([], provider, state, execution_result) do
    [
      Event.new(:result,
        provider: provider,
        payload:
          Payload.Result.new(
            status: if(state == "completed", do: :completed, else: :failed),
            stop_reason: state,
            output: execution_result.output,
            metadata: %{runtime_execution_status: execution_result.status}
          )
      )
    ]
  end

  defp ensure_terminal_event(events, _provider, _state, _execution_result), do: events

  defp decorate_terminal_event(
         %Event{kind: :result, payload: %Payload.Result{} = payload} = event,
         execution_result
       ) do
    payload = %{
      payload
      | output: payload.output || execution_result.output,
        metadata: Map.put(payload.metadata, :runtime_execution_status, execution_result.status)
    }

    %{event | payload: payload}
  end

  defp decorate_terminal_event(event, _execution_result), do: event

  defp safe_profile_call(profile, function, args, parser_state) do
    case apply(profile, function, args) do
      {events, next_parser_state} when is_list(events) ->
        {Enum.filter(events, &match?(%Event{}, &1)), next_parser_state}

      _invalid ->
        {[], parser_state}
    end
  rescue
    _error -> {[], parser_state}
  catch
    _kind, _reason -> {[], parser_state}
  end

  defp normalize_events(entry, events, runtime_event) do
    metadata = runtime_metadata(entry, runtime_event)

    Enum.map_reduce(events, entry, fn event, current ->
      sequence = current.sequence + 1

      event =
        %{
          event
          | sequence: sequence,
            timestamp: runtime_event.emitted_at,
            metadata: Map.merge(event.metadata, metadata),
            raw: nil
        }
        |> GovernedSecurity.sanitize_event(current.authority)

      {event, %{current | sequence: sequence}}
    end)
    |> then(fn {events, entry} -> {entry, events} end)
  end

  defp runtime_metadata(entry, runtime_event) do
    %{
      execution_ref: entry.execution_ref.ref,
      execution_mode: :runtime_client,
      runtime_sequence: runtime_event.sequence
    }
  end

  defp project_status(entry, runtime_status) do
    state = terminal_state(entry, runtime_status.state)
    session = %{entry.session | state: state}

    status =
      GatewayStatus.new(%{
        session_ref: session.session_ref,
        generation: session.generation,
        state: state,
        sequence: entry.sequence,
        input_open: runtime_status.input_open,
        output_open: runtime_status.output_open,
        receipt_ref: runtime_status.receipt_ref,
        exit_status: exit_status(state),
        error_ref: status_error_ref(entry, state, runtime_status.error)
      })

    case status do
      {:ok, status} ->
        {:ok,
         %{
           entry
           | session: session,
             input_open: status.input_open,
             output_open: status.output_open,
             terminal_status: if(terminal?(state), do: status, else: nil)
         }, status}

      {:error, _reason} ->
        {:error, error(:transport_lost, "runtime_status_invalid", false)}
    end
  end

  defp terminal_status(entry, receipt_ref, execution_result) do
    state = entry.session.state

    {:ok, status} =
      GatewayStatus.new(%{
        session_ref: entry.session.session_ref,
        generation: entry.session.generation,
        state: state,
        sequence: entry.sequence,
        input_open: false,
        output_open: false,
        receipt_ref: receipt_ref,
        exit_status: exit_status(state),
        error_ref: result_error_ref(entry, state, execution_result)
      })

    status
  end

  defp terminal_state(%{terminal_override: override}, _runtime_state)
       when override in ["cancelled", "terminated"],
       do: override

  defp terminal_state(_entry, "accepted"), do: "starting"
  defp terminal_state(_entry, state) when state in @gateway_states, do: state
  defp terminal_state(_entry, _state), do: "ambiguous"

  defp active_state("accepted"), do: "starting"
  defp active_state(state) when state in ["running", "backpressured"], do: state

  defp exit_status("completed"), do: 0
  defp exit_status("cancelled"), do: 130
  defp exit_status("terminated"), do: 143
  defp exit_status(state) when state in ["failed", "ambiguous"], do: 1
  defp exit_status(_state), do: nil

  defp status_error_ref(_entry, "completed", _runtime_error), do: nil

  defp status_error_ref(_entry, state, _runtime_error)
       when state in ["starting", "running", "backpressured"],
       do: nil

  defp status_error_ref(entry, state, %RuntimeError{evidence_ref: evidence_ref}) do
    if Support.ref?(evidence_ref), do: evidence_ref, else: error_ref(entry, state)
  end

  defp status_error_ref(entry, state, _runtime_error), do: error_ref(entry, state)

  defp result_error_ref(_entry, "completed", _execution_result), do: nil

  defp result_error_ref(entry, state, %ExecutionResult{error: execution_error})
       when is_map(execution_error) do
    case value(execution_error, :evidence_ref) do
      evidence_ref when is_binary(evidence_ref) ->
        if Support.ref?(evidence_ref), do: evidence_ref, else: error_ref(entry, state)

      _missing ->
        error_ref(entry, state)
    end
  end

  defp result_error_ref(entry, state, _execution_result), do: error_ref(entry, state)

  defp error_ref(entry, state) do
    token =
      :crypto.hash(:sha256, "#{entry.session.session_ref}:#{entry.session.generation}:#{state}")
      |> Base.url_encode64(padding: false)

    "error://cli-core/runtime-client/#{token}/#{state}"
  end

  defp active_entry(state, session) do
    with {:ok, entry} <- entry(state, session),
         false <- GatewaySession.terminal?(entry.session) do
      {:ok, entry}
    else
      true -> {:error, error(:terminal, "session_terminal", false)}
      {:error, %Error{} = gateway_error} -> {:error, gateway_error}
    end
  end

  defp entry(state, session) do
    case Map.fetch(state.sessions, session_key(session)) do
      {:ok, %{session: stored_session} = entry}
      when stored_session.contract_version == session.contract_version and
             stored_session.session_ref == session.session_ref and
             stored_session.generation == session.generation and
             stored_session.execution_ref == session.execution_ref and
             stored_session.fence == session.fence ->
        {:ok, entry}

      {:ok, _mismatch} ->
        {:error, error(:unauthorized, "session_identity_mismatch", false)}

      :error ->
        {:error, error(:invalid_request, "session_not_found", false)}
    end
  end

  defp ensure_startable_request(request) do
    if DateTime.compare(request.deadline_at, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, error(:expired, "start_request_expired", false)}
    end
  end

  defp ensure_unclaimed(key, state) do
    if Map.has_key?(state.bindings, key) or Map.has_key?(state.sessions, key) do
      {:error, error(:invalid_request, "session_identity_already_claimed", false)}
    else
      :ok
    end
  end

  defp runtime_reply(module, function, args, reason_code) do
    case safe_runtime_call(module, function, args) do
      :ok -> :ok
      {:error, reason} -> {:error, runtime_error(reason, reason_code)}
      _invalid -> {:error, error(:transport_lost, "#{reason_code}_invalid", false)}
    end
  end

  defp runtime_result(module, function, args, reason_code) do
    case safe_runtime_call(module, function, args) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, runtime_error(reason, reason_code)}
      _invalid -> {:error, error(:transport_lost, "#{reason_code}_invalid", false)}
    end
  end

  defp safe_runtime_call(module, function, args) do
    apply(module, function, args)
  rescue
    _error -> {:error, :runtime_client_exception}
  catch
    :exit, _reason -> {:error, :runtime_client_exit}
    _kind, _reason -> {:error, :runtime_client_failure}
  end

  # An unrecognized category reads as a lost transport rather than as a
  # specific failure: claiming to know which one it was would be a guess, and a
  # retryable guess at that.
  @runtime_error_categories %{
    "invalid_request" => :invalid_request,
    "rejected" => :unauthorized,
    "unavailable" => :unavailable,
    "timeout" => :timeout,
    "backpressure" => :backpressure,
    "cancelled" => :cancelled,
    "transport_lost" => :transport_lost,
    "ambiguous" => :ambiguous,
    "terminal" => :terminal
  }

  defp runtime_error(%RuntimeError{} = runtime_error, reason_code) do
    error(
      Map.get(@runtime_error_categories, runtime_error.category, :transport_lost),
      "#{reason_code}_#{runtime_error.category}",
      runtime_error.retryable,
      runtime_error.evidence_ref
    )
  end

  defp runtime_error(_reason, reason_code),
    do: error(:unavailable, "#{reason_code}_unavailable", true)

  # A terminal event stops delivery to this entry's subscribers and schedules
  # the entry's own removal. Retention is not immediate: a subscriber that
  # arrives just after the end still needs to be able to read how it ended.
  defp dispatch_runtime_event(state, key, execution_ref, runtime_event) do
    entry = Map.fetch!(state.sessions, key)

    case consume_runtime_event(entry, execution_ref, runtime_event) do
      {:ok, entry, events, terminal_status} ->
        deliver_events(entry, events)
        deliver_terminal(entry, terminal_status)
        put_entry(state, key, retire_if_terminal(entry, key, terminal_status))

      :ignore ->
        state
    end
  end

  defp retire_if_terminal(entry, _key, nil), do: entry

  defp retire_if_terminal(entry, key, _terminal_status) do
    Process.send_after(self(), {:forget_terminal, key}, @terminal_retention_ms)
    %{entry | subscribers: MapSet.new()}
  end

  defp deliver_events(entry, events) do
    Enum.each(entry.subscribers, fn subscriber ->
      Enum.each(events, fn event ->
        send(subscriber, {@event_message, entry.session, event})
      end)
    end)
  end

  defp deliver_terminal(_entry, nil), do: :ok

  defp deliver_terminal(entry, terminal_status) do
    Enum.each(entry.subscribers, fn subscriber ->
      send(subscriber, {@terminal_message, entry.session, terminal_status})
    end)
  end

  defp consume_binding(state, key, binding) do
    Process.demonitor(binding.owner_monitor, [:flush])

    %{
      state
      | bindings: Map.delete(state.bindings, key),
        binding_monitors: Map.delete(state.binding_monitors, binding.owner_monitor)
    }
  end

  defp drop_binding_monitor(state, key, monitor) do
    case Map.pop(state.bindings, key) do
      {nil, bindings} ->
        %{
          state
          | bindings: bindings,
            binding_monitors: Map.delete(state.binding_monitors, monitor)
        }

      {binding, bindings} ->
        run_teardown(binding)

        %{
          state
          | bindings: bindings,
            binding_monitors: Map.delete(state.binding_monitors, monitor)
        }
    end
  end

  defp put_entry(state, key, entry),
    do: %{state | sessions: Map.put(state.sessions, key, entry)}

  defp session_key(%{session_ref: session_ref, generation: generation}),
    do: {session_ref, generation}

  # `metadata` is always a map here: it comes from %Options{}, whose metadata
  # field is map-typed, so a non-map head is unreachable.
  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp value(_value, _key), do: nil

  defp terminal?(state), do: state in @terminal_states

  defp run_teardown(%{teardown_done?: true} = entry), do: entry

  defp run_teardown(%{teardown: teardown} = entry) do
    safe_teardown(teardown)
    %{entry | teardown_done?: true, teardown: nil}
  end

  defp run_teardown(entry), do: entry

  defp safe_teardown(teardown) when is_function(teardown, 0) do
    teardown.()
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_teardown(_teardown), do: :ok

  defp call(message) do
    GenServer.call(@server, message, 15_000)
  catch
    :exit, _reason -> {:error, error(:unavailable, "runtime_gateway_unavailable", true)}
  end

  defp error(category, reason_code, retryable, evidence_ref \\ nil) do
    evidence_ref = if Support.ref?(evidence_ref), do: evidence_ref

    {:ok, gateway_error} =
      Error.new(%{
        category: category,
        reason_code: reason_code,
        retryable: retryable,
        ambiguous: category == :ambiguous,
        evidence_ref: evidence_ref
      })

    gateway_error
  end
end
