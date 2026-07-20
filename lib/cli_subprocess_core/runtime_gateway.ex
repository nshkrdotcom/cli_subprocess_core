defmodule CliSubprocessCore.RuntimeGateway.Support do
  @moduledoc false

  @forbidden_keys MapSet.new(~w(
    access_token api_key auth_root authorization base_url client_secret config_root
    credential cwd env environment home material password private_key raw_credential
    refresh_token secret token
  ))

  def attrs(%_{} = value), do: Map.from_struct(value)

  def attrs(value) when is_list(value) do
    if Enum.all?(value, &match?({_, _}, &1)),
      do: Map.new(value),
      else: %{__invalid_input__: true}
  end

  def attrs(value) when is_map(value), do: value

  def value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  def known_fields?(attrs, fields) do
    allowed = MapSet.new(Enum.flat_map(fields, &[&1, Atom.to_string(&1)]))
    Enum.all?(Map.keys(attrs), &MapSet.member?(allowed, &1))
  end

  def safe_input?(%DateTime{}), do: true

  def safe_input?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      normalized = key |> to_string() |> String.downcase()
      not forbidden_key?(normalized) and safe_input?(nested)
    end)
  end

  def safe_input?(values) when is_list(values), do: Enum.all?(values, &safe_input?/1)

  def safe_input?(value)
      when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
      do: safe_scalar?(value)

  def safe_input?(value) when is_atom(value), do: true

  def safe_input?(_value), do: false

  def ref?(value) when is_binary(value) do
    byte_size(value) <= 512 and String.valid?(value) and value != "" and
      String.trim(value) == value and not absolute_path?(value) and
      not String.match?(value, ~r/[\x00-\x1f\x7f]/)
  end

  def ref?(_value), do: false

  def reason_code?(value) when is_binary(value) do
    byte_size(value) <= 128 and String.match?(value, ~r/\A[a-z][a-z0-9_.:-]*\z/)
  end

  def reason_code?(_value), do: false

  def digest?("sha256:" <> hex),
    do: byte_size(hex) == 64 and String.match?(hex, ~r/\A[0-9a-f]{64}\z/)

  def digest?(_value), do: false
  def positive_integer?(value), do: is_integer(value) and value > 0
  def non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp forbidden_key?(key),
    do:
      MapSet.member?(@forbidden_keys, key) or String.starts_with?(key, "raw_") or
        String.ends_with?(key, ["_api_key", "_password", "_private_key", "_secret", "_token"])

  defp safe_scalar?(value) when is_binary(value) do
    byte_size(value) <= 1_024 and String.valid?(value) and not absolute_path?(value) and
      not String.match?(value, ~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
  end

  defp safe_scalar?(_value), do: true

  defp absolute_path?(value) when is_binary(value) do
    String.starts_with?(value, ["/", "~/"]) or
      String.match?(value, ~r/\A[A-Za-z]:[\\\/]/)
  end

  defp absolute_path?(_value), do: false
end

defmodule CliSubprocessCore.RuntimeGateway.Error do
  @moduledoc "Bounded, secret-free local RuntimeGateway error envelope."

  alias CliSubprocessCore.RuntimeGateway.Support, as: S

  @categories ~w(
    invalid_request unauthorized expired revoked unavailable timeout backpressure
    cancelled transport_lost ambiguous terminal
  )
  @fields [:category, :reason_code, :retryable, :ambiguous, :evidence_ref]
  @enforce_keys @fields -- [:evidence_ref]
  defstruct @fields

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = S.attrs(attrs)
    category = attrs |> S.value(:category) |> normalize_string()

    error = %__MODULE__{
      category: category,
      reason_code: S.value(attrs, :reason_code),
      retryable: S.value(attrs, :retryable, false),
      ambiguous: S.value(attrs, :ambiguous, false),
      evidence_ref: S.value(attrs, :evidence_ref)
    }

    if S.known_fields?(attrs, @fields) and S.safe_input?(attrs) and
         error.category in @categories and S.reason_code?(error.reason_code) and
         is_boolean(error.retryable) and is_boolean(error.ambiguous) and
         optional_ref?(error.evidence_ref) and
         error.ambiguous == (error.category == "ambiguous") do
      {:ok, error}
    else
      {:error, :invalid_runtime_gateway_error}
    end
  end

  def new(_attrs), do: {:error, :invalid_runtime_gateway_error}

  defp optional_ref?(nil), do: true
  defp optional_ref?(value), do: S.ref?(value)
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value
end

defmodule CliSubprocessCore.RuntimeGateway.StartRequest do
  @moduledoc "Secret-free local CLI session start contract."

  alias CliSubprocessCore.RuntimeGateway.Support, as: S

  @fields [
    :contract_version,
    :session_ref,
    :generation,
    :command_ref,
    :command_digest,
    :working_directory_ref,
    :environment_materialization_ref,
    :authority_ref,
    :target_ref,
    :operation_ref,
    :deadline_at,
    :fence
  ]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = S.attrs(attrs)

    request = %__MODULE__{
      contract_version: S.value(attrs, :contract_version, 1),
      session_ref: S.value(attrs, :session_ref),
      generation: S.value(attrs, :generation),
      command_ref: S.value(attrs, :command_ref),
      command_digest: S.value(attrs, :command_digest),
      working_directory_ref: S.value(attrs, :working_directory_ref),
      environment_materialization_ref: S.value(attrs, :environment_materialization_ref),
      authority_ref: S.value(attrs, :authority_ref),
      target_ref: S.value(attrs, :target_ref),
      operation_ref: S.value(attrs, :operation_ref),
      deadline_at: S.value(attrs, :deadline_at),
      fence: S.value(attrs, :fence)
    }

    refs = [
      request.session_ref,
      request.command_ref,
      request.working_directory_ref,
      request.environment_materialization_ref,
      request.authority_ref,
      request.target_ref,
      request.operation_ref
    ]

    if S.known_fields?(attrs, @fields) and S.safe_input?(attrs) and
         request.contract_version == 1 and Enum.all?(refs, &S.ref?/1) and
         S.positive_integer?(request.generation) and S.digest?(request.command_digest) and
         is_struct(request.deadline_at, DateTime) and S.non_negative_integer?(request.fence) do
      {:ok, request}
    else
      {:error, :invalid_runtime_gateway_start_request}
    end
  end

  def new(_attrs), do: {:error, :invalid_runtime_gateway_start_request}

  def new!(attrs) do
    case new(attrs) do
      {:ok, request} -> request
      {:error, reason} -> raise ArgumentError, Atom.to_string(reason)
    end
  end
end

defmodule CliSubprocessCore.RuntimeGateway.Session do
  @moduledoc "Opaque local CLI session identity; never a process identifier."

  alias CliSubprocessCore.RuntimeGateway.Support, as: S

  @states ~w(starting running backpressured completed failed cancelled ambiguous terminated)
  @terminal_states ~w(completed failed cancelled ambiguous terminated)
  @fields [:contract_version, :session_ref, :generation, :execution_ref, :state, :fence]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = S.attrs(attrs)
    state = attrs |> S.value(:state) |> normalize_string()

    session = %__MODULE__{
      contract_version: S.value(attrs, :contract_version, 1),
      session_ref: S.value(attrs, :session_ref),
      generation: S.value(attrs, :generation),
      execution_ref: S.value(attrs, :execution_ref),
      state: state,
      fence: S.value(attrs, :fence)
    }

    if S.known_fields?(attrs, @fields) and S.safe_input?(attrs) and
         session.contract_version == 1 and S.ref?(session.session_ref) and
         S.positive_integer?(session.generation) and S.ref?(session.execution_ref) and
         session.state in @states and S.non_negative_integer?(session.fence) do
      {:ok, session}
    else
      {:error, :invalid_runtime_gateway_session}
    end
  end

  def new(_attrs), do: {:error, :invalid_runtime_gateway_session}

  def new!(attrs) do
    case new(attrs) do
      {:ok, session} -> session
      {:error, reason} -> raise ArgumentError, Atom.to_string(reason)
    end
  end

  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states
  def states, do: @states
  def terminal_states, do: @terminal_states

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value
end

defmodule CliSubprocessCore.RuntimeGateway.Status do
  @moduledoc "Bounded local CLI lifecycle and receipt status."

  alias CliSubprocessCore.RuntimeGateway.{Session, Support}

  @fields [
    :session_ref,
    :generation,
    :state,
    :sequence,
    :input_open,
    :output_open,
    :receipt_ref,
    :exit_status,
    :error_ref
  ]
  @enforce_keys @fields -- [:receipt_ref, :exit_status, :error_ref]
  defstruct @fields

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Support.attrs(attrs)
    state = attrs |> Support.value(:state) |> normalize_string()

    status = %__MODULE__{
      session_ref: Support.value(attrs, :session_ref),
      generation: Support.value(attrs, :generation),
      state: state,
      sequence: Support.value(attrs, :sequence),
      input_open: Support.value(attrs, :input_open),
      output_open: Support.value(attrs, :output_open),
      receipt_ref: Support.value(attrs, :receipt_ref),
      exit_status: Support.value(attrs, :exit_status),
      error_ref: Support.value(attrs, :error_ref)
    }

    terminal? = status.state in Session.terminal_states()

    terminal_coherent? = terminal_coherent?(status, terminal?)

    if Support.known_fields?(attrs, @fields) and Support.safe_input?(attrs) and
         Support.ref?(status.session_ref) and Support.positive_integer?(status.generation) and
         status.state in Session.states() and Support.non_negative_integer?(status.sequence) and
         is_boolean(status.input_open) and is_boolean(status.output_open) and
         optional_ref?(status.receipt_ref) and optional_ref?(status.error_ref) and
         optional_exit_status?(status.exit_status) and terminal_coherent? do
      {:ok, status}
    else
      {:error, :invalid_runtime_gateway_status}
    end
  end

  def new(_attrs), do: {:error, :invalid_runtime_gateway_status}

  defp optional_ref?(nil), do: true
  defp optional_ref?(value), do: Support.ref?(value)
  defp optional_exit_status?(nil), do: true
  defp optional_exit_status?(value), do: is_integer(value) and value >= 0 and value <= 255

  defp terminal_coherent?(status, false) do
    is_nil(status.receipt_ref) and is_nil(status.exit_status)
  end

  defp terminal_coherent?(status, true) do
    streams_closed? = status.input_open == false and status.output_open == false
    receipt? = Support.ref?(status.receipt_ref)

    outcome_coherent? =
      case status.state do
        "completed" -> status.exit_status == 0 and is_nil(status.error_ref)
        "failed" -> status.exit_status != 0
        state when state in ["cancelled", "ambiguous", "terminated"] -> status.exit_status != 0
      end

    streams_closed? and receipt? and outcome_coherent?
  end

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value
end

defmodule CliSubprocessCore.RuntimeGateway do
  @moduledoc "Complete local CLI process lifecycle boundary."

  alias CliSubprocessCore.RuntimeGateway.{Error, Session, StartRequest, Status}

  @callback start_session(StartRequest.t()) :: {:ok, Session.t()} | {:error, Error.t()}
  @callback send_input(Session.t(), iodata()) :: :ok | {:error, Error.t()}
  @callback end_input(Session.t()) :: :ok | {:error, Error.t()}
  @callback info(Session.t()) :: {:ok, Status.t()} | {:error, Error.t()}
  @callback subscribe(Session.t(), pid()) :: :ok | {:error, Error.t()}
  @callback cancel(Session.t(), term()) :: :ok | {:error, Error.t()}
  @callback terminate(Session.t(), term()) :: :ok | {:error, Error.t()}
end
