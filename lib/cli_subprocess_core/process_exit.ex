defmodule CliSubprocessCore.ProcessExit do
  @moduledoc """
  Facade helpers for normalized process exits returned by core-owned lanes.

  Downstream SDKs should use this module instead of importing lower
  `ExecutionPlane.*` process-exit modules directly. The current runtime
  representation is intentionally opaque to product repos.
  """

  alias ExecutionPlane.ProcessExit, as: RuntimeProcessExit

  @opaque t :: RuntimeProcessExit.t()
  @type status :: :success | :exit | :signal | :error

  @doc """
  Returns true when `term` is the process-exit representation used by the core.
  """
  @spec match?(term()) :: boolean()
  def match?(%RuntimeProcessExit{}), do: true
  def match?(_term), do: false

  @doc """
  Normalizes a raw exit reason through the core facade.
  """
  @spec from_reason(term(), keyword()) :: t()
  def from_reason(reason, opts \\ []) when is_list(opts) do
    RuntimeProcessExit.from_reason(reason, opts)
  end

  @doc """
  Returns true when the normalized exit represents success.
  """
  @spec successful?(term()) :: boolean()
  def successful?(%RuntimeProcessExit{} = exit), do: RuntimeProcessExit.successful?(exit)
  def successful?(_term), do: false

  @doc """
  Returns the normalized exit status, or `nil` for non-exit terms.
  """
  @spec status(term()) :: status() | nil
  def status(%RuntimeProcessExit{status: status}), do: status
  def status(_term), do: nil

  @doc """
  Returns the normalized integer exit code, when present.
  """
  @spec code(term()) :: non_neg_integer() | nil
  def code(%RuntimeProcessExit{code: code}), do: code
  def code(_term), do: nil

  @doc """
  Returns the normalized signal, when present.
  """
  @spec signal(term()) :: atom() | integer() | nil
  def signal(%RuntimeProcessExit{signal: signal}), do: signal
  def signal(_term), do: nil

  @doc """
  Returns the original normalized reason, when present.
  """
  @spec reason(term()) :: term()
  def reason(%RuntimeProcessExit{reason: reason}), do: reason
  def reason(term), do: term

  @doc """
  Returns stderr carried on the exit, when present.
  """
  @spec stderr(term()) :: String.t() | nil
  def stderr(%RuntimeProcessExit{stderr: stderr}), do: stderr
  def stderr(_term), do: nil

  @doc """
  Projects the process exit to a map without exposing the lower module name.
  """
  @spec to_map(term()) :: map()
  def to_map(%RuntimeProcessExit{} = exit), do: Map.from_struct(exit)
  def to_map(term), do: %{reason: term}
end
