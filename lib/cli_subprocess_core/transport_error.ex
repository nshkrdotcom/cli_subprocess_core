defmodule CliSubprocessCore.TransportError do
  @moduledoc """
  Facade helpers for transport errors returned by core-owned lanes.

  Product SDKs should use this module to classify and project transport errors
  instead of matching lower `ExecutionPlane.*` structs directly.
  """

  alias ExecutionPlane.Process.Transport.Error, as: RuntimeTransportError

  @opaque t :: RuntimeTransportError.t()
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

  @doc """
  Returns true when `term` is the transport-error representation used by the core.
  """
  @spec match?(term()) :: boolean()
  def match?(%RuntimeTransportError{}), do: true
  def match?(_term), do: false

  @doc """
  Builds a normalized transport error through the core facade.
  """
  @spec transport_error(reason(), map()) :: t()
  def transport_error(reason, context \\ %{}) when is_map(context) do
    RuntimeTransportError.transport_error(reason, context)
  end

  @doc """
  Returns the normalized transport reason, or the original term for non-errors.
  """
  @spec reason(term()) :: reason()
  def reason(%RuntimeTransportError{reason: reason}), do: reason
  def reason(term), do: term

  @doc """
  Returns the transport error message, or an inspected fallback.
  """
  @spec message(term()) :: String.t()
  def message(%RuntimeTransportError{message: message}), do: message
  def message(term), do: inspect(term)

  @doc """
  Returns transport context, or an empty map for non-errors.
  """
  @spec context(term()) :: map()
  def context(%RuntimeTransportError{context: context}) when is_map(context), do: context
  def context(_term), do: %{}

  @doc """
  Projects the transport error to a map without exposing the lower module name.
  """
  @spec to_map(term()) :: %{reason: term(), message: String.t(), context: map()}
  def to_map(%RuntimeTransportError{} = error) do
    %{
      reason: error.reason,
      message: error.message,
      context: error.context
    }
  end

  def to_map(term), do: %{reason: term, message: inspect(term), context: %{}}
end
