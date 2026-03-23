defmodule CliSubprocessCore.Transport.Info do
  @moduledoc """
  Snapshot of a long-lived transport's subprocess metadata and IO contract.
  """

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Transport.Delivery

  defstruct invocation: nil,
            pid: nil,
            os_pid: nil,
            status: :disconnected,
            stdout_mode: :line,
            stdin_mode: :line,
            pty?: false,
            interrupt_mode: :signal,
            stderr: "",
            delivery: nil

  @type t :: %__MODULE__{
          invocation: Command.t() | nil,
          pid: pid() | nil,
          os_pid: pos_integer() | nil,
          status: :connected | :disconnected | :error,
          stdout_mode: :line | :raw,
          stdin_mode: :line | :raw,
          pty?: boolean(),
          interrupt_mode: :signal | {:stdin, binary()},
          stderr: binary(),
          delivery: Delivery.t() | nil
        }

  @doc """
  Returns the default disconnected transport snapshot.
  """
  def disconnected do
    %__MODULE__{delivery: Delivery.new(:cli_subprocess_core)}
  end
end
