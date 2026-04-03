defmodule CliSubprocessCore.Command.RunResult do
  @moduledoc """
  Core-owned result for provider-aware one-shot command execution.
  """

  alias CliSubprocessCore.Command
  alias ExternalRuntimeTransport.ProcessExit
  alias ExternalRuntimeTransport.Transport.RunResult, as: TransportRunResult

  @enforce_keys [:invocation, :exit]
  defstruct invocation: nil,
            output: "",
            stdout: "",
            stderr: "",
            exit: nil,
            stderr_mode: :separate

  @type stderr_mode :: :separate | :stdout

  @type t :: %__MODULE__{
          invocation: Command.t(),
          output: binary(),
          stdout: binary(),
          stderr: binary(),
          exit: ProcessExit.t(),
          stderr_mode: stderr_mode()
        }

  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{exit: %ProcessExit{} = exit}) do
    ProcessExit.successful?(exit)
  end

  @spec from_transport(TransportRunResult.t(), Command.t()) :: t()
  def from_transport(%TransportRunResult{} = result, %Command{} = invocation) do
    %__MODULE__{
      invocation: invocation,
      output: result.output,
      stdout: result.stdout,
      stderr: result.stderr,
      exit: result.exit,
      stderr_mode: result.stderr_mode
    }
  end
end
