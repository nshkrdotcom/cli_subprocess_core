defmodule CliSubprocessCore.Transport.RunResult do
  @moduledoc """
  Captured output and normalized exit data for one-shot non-PTY execution.
  """

  alias CliSubprocessCore.{Command, ProcessExit}

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

  @doc """
  Returns `true` when the captured execution completed successfully.
  """
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{exit: %ProcessExit{} = exit}) do
    ProcessExit.successful?(exit)
  end
end
