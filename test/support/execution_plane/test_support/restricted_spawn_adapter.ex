defmodule ExecutionPlane.TestSupport.RestrictedSpawnAdapter do
  @moduledoc false

  alias ExecutionPlane.Command
  alias ExecutionPlane.Process.Transport
  alias ExecutionPlane.Process.Transport.{Error, Subprocess}
  alias ExecutionPlane.Process.Transport.Surface.Adapter
  alias ExecutionPlane.Process.Transport.Surface.Capabilities

  @behaviour Adapter
  @behaviour Transport

  @impl Adapter
  def surface_kind, do: :test_restricted_spawn

  @impl Adapter
  def capabilities do
    Capabilities.new!(
      remote?: false,
      startup_kind: :spawn,
      path_semantics: :local,
      supports_run?: false,
      supports_streaming_stdio?: true,
      supports_pty?: false,
      supports_user?: false,
      supports_env?: false,
      supports_cwd?: false,
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
  def run(%Command{}, _opts) do
    {:error, {:transport, Error.unsupported_capability(:run, :test_restricted_spawn)}}
  end

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
