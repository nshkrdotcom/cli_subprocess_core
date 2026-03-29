defmodule CliSubprocessCore.Transport.LocalSubprocess do
  @moduledoc false

  alias CliSubprocessCore.ExecutionSurface.Adapter
  alias CliSubprocessCore.ExecutionSurface.Capabilities
  alias CliSubprocessCore.Transport
  alias CliSubprocessCore.Transport.Subprocess

  @behaviour Adapter
  @behaviour Transport

  @impl Adapter
  def surface_kind, do: :local_subprocess

  @impl Adapter
  def capabilities do
    Capabilities.new!(
      remote?: false,
      startup_kind: :spawn,
      path_semantics: :local,
      supports_run?: true,
      supports_streaming_stdio?: true,
      supports_pty?: true,
      supports_user?: true,
      supports_env?: true,
      supports_cwd?: true,
      interrupt_kind: :signal
    )
  end

  @impl Adapter
  def normalize_transport_options(nil), do: {:ok, []}

  def normalize_transport_options(options) when is_list(options) do
    if Keyword.keyword?(options) and options == [] do
      {:ok, []}
    else
      {:error, {:invalid_transport_options, options}}
    end
  end

  def normalize_transport_options(options) when is_map(options) and map_size(options) == 0,
    do: {:ok, []}

  def normalize_transport_options(options), do: {:error, {:invalid_transport_options, options}}

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
