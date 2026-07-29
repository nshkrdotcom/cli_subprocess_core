defmodule CliSubprocessCore.RuntimeGateway.Local.SessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end

defmodule CliSubprocessCore.RuntimeGateway.Local do
  @moduledoc """
  Supervised local implementation of the frozen CLI RuntimeGateway lifecycle.

  The public start contract is intentionally secret-free. Before start, the
  credential/materialization owner binds that exact request to one governed
  `CliSubprocessCore.Session` launch with `bind_start/2`. The binding is
  caller-owned, in-memory, one-shot, and consumed before process dispatch.

  Public sessions contain only opaque references. Raw process identifiers and
  launch material remain inside this supervised owner and are discarded when
  start fails or the session reaches a terminal state.
  """

  @behaviour CliSubprocessCore.RuntimeGateway

  alias CliSubprocessCore.Event
  alias CliSubprocessCore.GovernedAuthority
  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.RuntimeGateway.CommandBinding
  alias CliSubprocessCore.RuntimeGateway.Error
  alias CliSubprocessCore.RuntimeGateway.Session, as: GatewaySession
  alias CliSubprocessCore.RuntimeGateway.StartRequest
  alias CliSubprocessCore.RuntimeGateway.Status
  alias CliSubprocessCore.Session
  alias CliSubprocessCore.Session.Options

  @server __MODULE__
  @session_supervisor __MODULE__.SessionSupervisor
  @event_message :cli_subprocess_core_runtime_gateway_event
  @terminal_message :cli_subprocess_core_runtime_gateway_terminal
  @terminal_retention_ms 60_000

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

  Local sessions enter the supervised process transport directly and are not
  Runtime Client-admitted executions.
  """
  @spec execution_mode() :: :local
  def execution_mode, do: :local

  @doc "Returns the stable tag used for incremental CLI gateway events."
  @spec event_message_tag() :: :cli_subprocess_core_runtime_gateway_event
  def event_message_tag, do: @event_message

  @doc "Returns the stable tag used for terminal CLI gateway status."
  @spec terminal_message_tag() :: :cli_subprocess_core_runtime_gateway_terminal
  def terminal_message_tag, do: @terminal_message

  @doc """
  Binds a frozen start request to one exact governed local launch.

  Only the binding process may consume the binding. A binding disappears when
  its owner exits, when start is attempted, or when validation fails. The
  command digest covers the exact governed executable, workspace, isolated
  environment, and clear-environment posture.
  """
  @spec bind_start(StartRequest.t(), keyword()) :: :ok | {:error, bind_error()}
  def bind_start(%StartRequest{} = request, session_opts) when is_list(session_opts) do
    call({:bind_start, request, session_opts})
  end

  def bind_start(_request, _session_opts),
    do: {:error, error(:invalid_request, "invalid_start_binding", false)}

  @doc "Returns the digest required in `StartRequest.command_digest`."
  @spec command_digest(GovernedAuthority.t()) :: String.t()
  defdelegate command_digest(authority), to: CommandBinding, as: :digest

  @impl true
  def start_session(%StartRequest{} = request), do: call({:start_session, request})

  def start_session(_request),
    do: {:error, error(:invalid_request, "invalid_start_request", false)}

  @impl true
  def send_input(%GatewaySession{} = session, input) do
    call({:send_input, session, input})
  end

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
  def subscribe(%GatewaySession{} = session, subscriber) when is_pid(subscriber) do
    call({:subscribe, session, subscriber})
  end

  def subscribe(_session, _subscriber),
    do: {:error, error(:invalid_request, "invalid_subscription", false)}

  @impl true
  def cancel(%GatewaySession{} = session, reason), do: call({:cancel, session, reason})

  def cancel(_session, _reason),
    do: {:error, error(:invalid_request, "invalid_session", false)}

  @impl true
  def terminate(%GatewaySession{} = session, reason),
    do: call({:terminate, session, reason})

  def terminate(_session, _reason),
    do: {:error, error(:invalid_request, "invalid_session", false)}

  def init(:ok) do
    {:ok,
     %{
       bindings: %{},
       binding_monitors: %{},
       sessions: %{},
       session_monitors: %{},
       tags: %{}
     }}
  end

  def handle_call({:bind_start, request, session_opts}, {owner, _tag}, state) do
    key = session_key(request)

    with :ok <- ensure_startable_request(request),
         :ok <- ensure_unclaimed(key, state),
         {:ok, options} <- Options.new(session_opts),
         :ok <- validate_binding(request, options, session_opts) do
      monitor = Process.monitor(owner)

      binding = %{
        owner: owner,
        owner_monitor: monitor,
        request: request,
        session_opts: session_opts
      }

      {:reply, :ok,
       %{
         state
         | bindings: Map.put(state.bindings, key, binding),
           binding_monitors: Map.put(state.binding_monitors, monitor, key)
       }}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:start_session, request}, {owner, _tag}, state) do
    key = session_key(request)

    case Map.fetch(state.bindings, key) do
      {:ok, %{owner: ^owner, request: ^request} = binding} ->
        state = consume_binding(state, key, binding)

        case ensure_startable_request(request) do
          :ok ->
            start_bound_session(request, binding.session_opts, key, state)

          {:error, %Error{} = error} ->
            {:reply, {:error, error}, state}
        end

      {:ok, %{owner: ^owner}} ->
        {:reply, {:error, error(:unauthorized, "start_request_mismatch", false)}, state}

      {:ok, _other_owner} ->
        {:reply, {:error, error(:unauthorized, "binding_owner_mismatch", false)}, state}

      :error ->
        {:reply, {:error, error(:unauthorized, "materialization_binding_missing", false)}, state}
    end
  end

  def handle_call({:send_input, session, input}, _from, state) do
    with {:ok, entry} <- active_entry(state, session),
         :ok <- normalize_runtime_reply(Session.send_input(entry.pid, input)) do
      {:reply, :ok, state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:end_input, session}, _from, state) do
    with {:ok, entry} <- active_entry(state, session),
         :ok <- normalize_runtime_reply(Session.end_input(entry.pid)) do
      entry = %{entry | input_open: false}
      {:reply, :ok, put_entry(state, session_key(session), entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:info, session}, _from, state) do
    case entry(state, session) do
      {:ok, entry} -> {:reply, {:ok, status(entry)}, state}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:subscribe, session, subscriber}, _from, state) do
    case entry(state, session) do
      {:ok, entry} ->
        entry = %{entry | subscribers: MapSet.put(entry.subscribers, subscriber)}
        {:reply, :ok, put_entry(state, session_key(session), entry)}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:cancel, session, _reason}, _from, state) do
    terminate_active(state, session, "cancelled", 130, :interrupt)
  end

  def handle_call({:terminate, session, _reason}, _from, state) do
    terminate_active(state, session, "terminated", 143, :close)
  end

  def handle_info({event_tag, tag, {:event, %Event{} = event}}, state)
      when is_atom(event_tag) and is_reference(tag) do
    case Map.fetch(state.tags, tag) do
      {:ok, key} ->
        entry = Map.fetch!(state.sessions, key)

        Enum.each(entry.subscribers, fn subscriber ->
          send(subscriber, {@event_message, entry.session, event})
        end)

        entry = %{
          entry
          | sequence: max(entry.sequence, event.sequence || entry.sequence),
            terminal_hint: terminal_hint(event, entry.terminal_hint)
        }

        {:noreply, put_entry(state, key, entry)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    cond do
      key = Map.get(state.binding_monitors, monitor) ->
        {:noreply, drop_binding_monitor(state, key, monitor)}

      key = Map.get(state.session_monitors, monitor) ->
        {:noreply, finalize_session(state, key, monitor)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:forget_terminal, key}, state) do
    case Map.get(state.sessions, key) do
      %{session: %GatewaySession{} = session} ->
        if GatewaySession.terminal?(session) do
          {:noreply, %{state | sessions: Map.delete(state.sessions, key)}}
        else
          {:noreply, state}
        end

      _missing ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_bound_session(request, session_opts, key, state) do
    tag = make_ref()

    child_spec =
      Supervisor.child_spec(
        {Session, Keyword.put(session_opts, :subscriber, {self(), tag})},
        id: {:runtime_gateway_local_session, key},
        restart: :temporary
      )

    case DynamicSupervisor.start_child(@session_supervisor, child_spec) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        session =
          GatewaySession.new!(%{
            session_ref: request.session_ref,
            generation: request.generation,
            execution_ref: execution_ref(request),
            state: "running",
            fence: request.fence
          })

        entry = %{
          pid: pid,
          monitor: monitor,
          tag: tag,
          session: session,
          sequence: 0,
          input_open: true,
          output_open: true,
          terminal_hint: nil,
          terminal_override: nil,
          subscribers: MapSet.new()
        }

        {:reply, {:ok, session},
         %{
           state
           | sessions: Map.put(state.sessions, key, entry),
             session_monitors: Map.put(state.session_monitors, monitor, key),
             tags: Map.put(state.tags, tag, key)
         }}

      {:error, _reason} ->
        {:reply, {:error, error(:unavailable, "local_session_start_failed", true)}, state}
    end
  end

  defp terminate_active(state, session, terminal_state, exit_status, mode) do
    with {:ok, entry} <- active_entry(state, session),
         :ok <- stop_session(entry.pid, mode) do
      entry = %{entry | terminal_override: {terminal_state, exit_status}}
      {:reply, :ok, put_entry(state, session_key(session), entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  defp stop_session(pid, :interrupt) do
    case Session.interrupt(pid) do
      :ok ->
        Session.close(pid)
        :ok

      {:error, _reason} ->
        {:error, error(:transport_lost, "local_session_interrupt_failed", false)}
    end
  end

  defp stop_session(pid, :close) do
    Session.close(pid)
    :ok
  end

  defp finalize_session(state, key, monitor) do
    case Map.fetch(state.sessions, key) do
      {:ok, entry} ->
        {terminal_state, exit_status, error_ref} = terminal_outcome(entry)

        session = %{entry.session | state: terminal_state}

        terminal = %{
          entry
          | pid: nil,
            monitor: nil,
            session: session,
            input_open: false,
            output_open: false,
            terminal_override: {terminal_state, exit_status},
            terminal_hint: error_ref,
            subscribers: MapSet.new()
        }

        terminal_status = status(terminal)
        Process.send_after(self(), {:forget_terminal, key}, @terminal_retention_ms)

        Enum.each(entry.subscribers, fn subscriber ->
          send(subscriber, {@terminal_message, session, terminal_status})
        end)

        %{
          state
          | sessions: Map.put(state.sessions, key, terminal),
            session_monitors: Map.delete(state.session_monitors, monitor),
            tags: Map.delete(state.tags, entry.tag)
        }

      :error ->
        %{state | session_monitors: Map.delete(state.session_monitors, monitor)}
    end
  end

  defp status(%{session: %GatewaySession{state: state}} = entry)
       when state in ["starting", "running", "backpressured"] do
    status!(%{
      session_ref: entry.session.session_ref,
      generation: entry.session.generation,
      state: state,
      sequence: entry.sequence,
      input_open: entry.input_open,
      output_open: entry.output_open,
      receipt_ref: nil,
      exit_status: nil,
      error_ref: nil
    })
  end

  defp status(entry) do
    {terminal_state, exit_status} = entry.terminal_override

    status!(%{
      session_ref: entry.session.session_ref,
      generation: entry.session.generation,
      state: terminal_state,
      sequence: entry.sequence,
      input_open: false,
      output_open: false,
      receipt_ref: receipt_ref(entry.session, terminal_state),
      exit_status: exit_status,
      error_ref: terminal_error_ref(terminal_state, entry.session)
    })
  end

  defp terminal_outcome(%{terminal_override: {state, exit_status}}),
    do: {state, exit_status, terminal_error_ref(state, nil)}

  defp terminal_outcome(%{terminal_hint: :completed}), do: {"completed", 0, nil}
  defp terminal_outcome(%{terminal_hint: :failed}), do: {"failed", 1, "runtime_failed"}
  defp terminal_outcome(_entry), do: {"ambiguous", 1, "provider_outcome_unknown"}

  defp terminal_hint(%Event{kind: :result, payload: %Payload.Result{status: status}}, _hint)
       when status in [:completed, "completed"],
       do: :completed

  defp terminal_hint(%Event{kind: :result}, _hint), do: :failed
  defp terminal_hint(%Event{kind: :error}, _hint), do: :failed
  defp terminal_hint(_event, hint), do: hint

  defp terminal_error_ref("completed", _session), do: nil

  defp terminal_error_ref(state, %GatewaySession{} = session),
    do: "error://cli-core/local/#{ref_token(session.session_ref)}/#{state}"

  defp terminal_error_ref(_state, nil), do: "runtime_failed"

  defp receipt_ref(session, state),
    do: "receipt://cli-core/local/#{ref_token(session.session_ref)}/#{state}"

  defp validate_binding(_request, %Options{governed_authority: nil}, _session_opts),
    do: {:error, error(:unauthorized, "governed_authority_required", false)}

  defp validate_binding(request, %Options{governed_authority: authority}, session_opts) do
    metadata = Keyword.get(session_opts, :metadata, %{})

    cond do
      Keyword.has_key?(session_opts, :subscriber) or Keyword.has_key?(session_opts, :starter) or
          Keyword.has_key?(session_opts, :name) ->
        {:error, error(:invalid_request, "gateway_owns_session_lifecycle", false)}

      authority.authority_ref != request.authority_ref ->
        {:error, error(:unauthorized, "authority_ref_mismatch", false)}

      authority.target_ref != request.target_ref ->
        {:error, error(:unauthorized, "target_ref_mismatch", false)}

      authority.command_ref != request.command_ref ->
        {:error, error(:unauthorized, "command_ref_mismatch", false)}

      metadata_value(metadata, :working_directory_ref) != request.working_directory_ref ->
        {:error, error(:unauthorized, "working_directory_ref_mismatch", false)}

      metadata_value(metadata, :environment_materialization_ref) !=
          request.environment_materialization_ref ->
        {:error, error(:unauthorized, "environment_materialization_ref_mismatch", false)}

      metadata_value(metadata, :operation_ref) != request.operation_ref ->
        {:error, error(:unauthorized, "operation_ref_mismatch", false)}

      authority.clear_env? != true ->
        {:error, error(:unauthorized, "ambient_environment_forbidden", false)}

      command_digest(authority) != request.command_digest ->
        {:error, error(:unauthorized, "command_digest_mismatch", false)}

      true ->
        :ok
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

  defp active_entry(state, session) do
    with {:ok, entry} <- entry(state, session),
         false <- GatewaySession.terminal?(entry.session),
         true <- is_pid(entry.pid) and Process.alive?(entry.pid) do
      {:ok, entry}
    else
      true -> {:error, error(:terminal, "session_terminal", false)}
      false -> {:error, error(:transport_lost, "local_session_unavailable", false)}
      {:error, %Error{} = error} -> {:error, error}
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

  defp normalize_runtime_reply(:ok), do: :ok

  defp normalize_runtime_reply({:error, _reason}),
    do: {:error, error(:transport_lost, "local_session_transport_failed", false)}

  defp normalize_runtime_reply(_other),
    do: {:error, error(:transport_lost, "local_session_transport_invalid", false)}

  defp consume_binding(state, key, binding) do
    Process.demonitor(binding.owner_monitor, [:flush])

    %{
      state
      | bindings: Map.delete(state.bindings, key),
        binding_monitors: Map.delete(state.binding_monitors, binding.owner_monitor)
    }
  end

  defp drop_binding_monitor(state, key, monitor) do
    %{
      state
      | bindings: Map.delete(state.bindings, key),
        binding_monitors: Map.delete(state.binding_monitors, monitor)
    }
  end

  defp put_entry(state, key, entry),
    do: %{state | sessions: Map.put(state.sessions, key, entry)}

  defp session_key(%{session_ref: session_ref, generation: generation}),
    do: {session_ref, generation}

  defp execution_ref(request),
    do: "execution://cli-core/local/#{ref_token("#{request.session_ref}:#{request.generation}")}"

  defp status!(attrs) do
    {:ok, status} = Status.new(attrs)
    status
  end

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))

  defp metadata_value(_metadata, _key), do: nil

  defp ref_token(value) do
    :crypto.hash(:sha256, value)
    |> Base.url_encode64(padding: false)
  end

  defp call(message) do
    GenServer.call(@server, message, 15_000)
  catch
    :exit, _reason -> {:error, error(:unavailable, "runtime_gateway_unavailable", true)}
  end

  defp error(category, reason_code, retryable) do
    {:ok, error} =
      Error.new(%{
        category: category,
        reason_code: reason_code,
        retryable: retryable,
        ambiguous: category == :ambiguous
      })

    error
  end
end
