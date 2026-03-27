defmodule CliSubprocessCore.Transport.LocalSubprocess do
  @moduledoc false

  alias CliSubprocessCore.Transport
  alias CliSubprocessCore.Transport.Subprocess

  @behaviour Transport

  @impl Transport
  defdelegate start(opts), to: Subprocess

  @impl Transport
  defdelegate start_link(opts), to: Subprocess

  @impl Transport
  defdelegate run(command, opts), to: Subprocess

  @impl Transport
  defdelegate send(transport, message), to: Subprocess

  @impl Transport
  defdelegate subscribe(transport, pid), to: Subprocess

  @impl Transport
  defdelegate subscribe(transport, pid, tag), to: Subprocess

  @impl Transport
  defdelegate unsubscribe(transport, pid), to: Subprocess

  @impl Transport
  defdelegate close(transport), to: Subprocess

  @impl Transport
  defdelegate force_close(transport), to: Subprocess

  @impl Transport
  defdelegate interrupt(transport), to: Subprocess

  @impl Transport
  defdelegate status(transport), to: Subprocess

  @impl Transport
  defdelegate end_input(transport), to: Subprocess

  @impl Transport
  defdelegate stderr(transport), to: Subprocess

  @impl Transport
  defdelegate info(transport), to: Subprocess
end
