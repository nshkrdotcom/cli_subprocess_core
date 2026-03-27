defmodule CliSubprocessCore.Transport.Info do
  @moduledoc """
  Snapshot of a long-lived transport's execution-surface metadata and IO contract.
  """

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Transport.ExecutionSurface
  alias CliSubprocessCore.Transport.Delivery

  defstruct invocation: nil,
            pid: nil,
            os_pid: nil,
            surface_kind: ExecutionSurface.default_surface_kind(),
            target_id: nil,
            lease_ref: nil,
            surface_ref: nil,
            boundary_class: nil,
            observability: %{},
            adapter_metadata: %{},
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
          surface_kind: ExecutionSurface.surface_kind(),
          target_id: String.t() | nil,
          lease_ref: String.t() | nil,
          surface_ref: String.t() | nil,
          boundary_class: atom() | nil,
          observability: map(),
          adapter_metadata: map(),
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
    %__MODULE__{
      delivery: Delivery.new(:cli_subprocess_core),
      observability: %{},
      adapter_metadata: %{}
    }
  end
end
