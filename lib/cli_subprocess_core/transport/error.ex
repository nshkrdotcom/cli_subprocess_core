defmodule CliSubprocessCore.Transport.Error do
  @moduledoc """
  Structured transport error with a normalized reason and debugging context.
  """

  defexception [:reason, :message, context: %{}]

  @type reason ::
          :not_connected
          | :timeout
          | :transport_stopped
          | {:unsupported_capability, atom(), atom()}
          | {:bridge_protocol_error, term()}
          | {:bridge_remote_error, term(), term()}
          | {:buffer_overflow, pos_integer(), pos_integer()}
          | {:send_failed, term()}
          | {:call_exit, term()}
          | {:command_not_found, String.t() | atom()}
          | {:cwd_not_found, String.t()}
          | {:invalid_options, term()}
          | {:startup_failed, term()}
          | term()

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          context: map()
        }

  @doc """
  Builds a generic transport error.
  """
  @spec transport_error(reason(), map()) :: t()
  def transport_error(reason, context \\ %{}) when is_map(context) do
    %__MODULE__{reason: reason, message: message_for(reason), context: context}
  end

  @doc """
  Builds a buffer overflow error with preview metadata.
  """
  @spec buffer_overflow(pos_integer(), pos_integer(), binary()) :: t()
  def buffer_overflow(actual_size, max_size, preview) do
    transport_error({:buffer_overflow, actual_size, max_size}, %{
      actual_size: actual_size,
      max_size: max_size,
      preview: preview
    })
  end

  @doc """
  Builds a send failure error.
  """
  @spec send_failed(term()) :: t()
  def send_failed(reason), do: transport_error({:send_failed, reason})

  @doc """
  Builds a not-connected error.
  """
  @spec not_connected() :: t()
  def not_connected, do: transport_error(:not_connected)

  @doc """
  Builds a timeout error.
  """
  @spec timeout() :: t()
  def timeout, do: transport_error(:timeout)

  @doc """
  Builds a transport-stopped error.
  """
  @spec transport_stopped() :: t()
  def transport_stopped, do: transport_error(:transport_stopped)

  @doc """
  Builds a call-exit error.
  """
  @spec call_exit(term()) :: t()
  def call_exit(reason), do: transport_error({:call_exit, reason})

  @doc """
  Builds a command-not-found error.
  """
  @spec command_not_found(String.t() | atom(), term()) :: t()
  def command_not_found(command, cause \\ nil) do
    context = if is_nil(cause), do: %{}, else: %{cause: cause}
    transport_error({:command_not_found, command}, context)
  end

  @doc """
  Builds a cwd-not-found error.
  """
  @spec cwd_not_found(String.t()) :: t()
  def cwd_not_found(cwd), do: transport_error({:cwd_not_found, cwd}, %{cwd: cwd})

  @doc """
  Builds an invalid-options error.
  """
  @spec invalid_options(term()) :: t()
  def invalid_options(reason), do: transport_error({:invalid_options, reason})

  @doc """
  Builds a startup-failed error.
  """
  @spec startup_failed(term()) :: t()
  def startup_failed(reason), do: transport_error({:startup_failed, reason})

  @doc """
  Builds an unsupported-capability error.
  """
  @spec unsupported_capability(atom(), atom()) :: t()
  def unsupported_capability(capability, surface_kind)
      when is_atom(capability) and is_atom(surface_kind) do
    transport_error({:unsupported_capability, capability, surface_kind}, %{
      capability: capability,
      surface_kind: surface_kind
    })
  end

  @doc """
  Builds a bridge-protocol error.
  """
  @spec bridge_protocol_error(term()) :: t()
  def bridge_protocol_error(reason), do: transport_error({:bridge_protocol_error, reason})

  @doc """
  Builds a bridge-remote error.
  """
  @spec bridge_remote_error(term(), term()) :: t()
  def bridge_remote_error(code, details),
    do: transport_error({:bridge_remote_error, code, details}, %{code: code, details: details})

  defp message_for(:not_connected), do: "Transport is not connected"
  defp message_for(:timeout), do: "Transport timeout"
  defp message_for(:transport_stopped), do: "Transport stopped before the operation completed"

  defp message_for({:buffer_overflow, actual_size, max_size}) do
    "Transport buffer exceeded #{max_size} bytes (got #{actual_size})"
  end

  defp message_for({:send_failed, reason}), do: "Transport send failed: #{inspect(reason)}"
  defp message_for({:call_exit, reason}), do: "Transport call exited: #{inspect(reason)}"

  defp message_for({:command_not_found, command}) do
    "Transport command not found: #{command}"
  end

  defp message_for({:cwd_not_found, cwd}), do: "Transport working directory not found: #{cwd}"

  defp message_for({:invalid_options, reason}),
    do: "Invalid transport options: #{inspect(reason)}"

  defp message_for({:startup_failed, reason}), do: "Transport startup failed: #{inspect(reason)}"

  defp message_for({:unsupported_capability, capability, surface_kind}) do
    "Transport capability #{inspect(capability)} is unsupported for #{inspect(surface_kind)}"
  end

  defp message_for({:bridge_protocol_error, reason}) do
    "Guest bridge protocol error: #{inspect(reason)}"
  end

  defp message_for({:bridge_remote_error, code, details}) do
    "Guest bridge remote error #{inspect(code)}: #{inspect(details)}"
  end

  defp message_for(reason), do: "Transport error: #{inspect(reason)}"
end
