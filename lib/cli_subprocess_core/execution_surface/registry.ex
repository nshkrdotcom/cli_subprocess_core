defmodule CliSubprocessCore.ExecutionSurface.Registry do
  @moduledoc """
  Internal registry of built-in execution-surface adapters.
  """

  @base_adapters %{
    local_subprocess: CliSubprocessCore.Transport.LocalSubprocess,
    ssh_exec: CliSubprocessCore.Transport.SSHExec,
    guest_bridge: CliSubprocessCore.Transport.GuestBridge
  }
  @optional_adapters %{
    test_guest_local: CliSubprocessCore.TestSupport.GuestLocalAdapter,
    test_restricted_spawn: CliSubprocessCore.TestSupport.RestrictedSpawnAdapter
  }

  @type fetch_error :: {:unsupported_surface_kind, atom() | term()}

  @spec supported_surface_kinds() :: [atom(), ...]
  def supported_surface_kinds do
    adapters()
    |> Map.keys()
    |> Enum.sort()
  end

  @spec registered?(term()) :: boolean()
  def registered?(surface_kind) when is_atom(surface_kind),
    do: Map.has_key?(adapters(), surface_kind)

  def registered?(_other), do: false

  @spec fetch(term()) :: {:ok, module()} | {:error, fetch_error()}
  def fetch(surface_kind) when is_atom(surface_kind) do
    case Map.fetch(adapters(), surface_kind) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_surface_kind, surface_kind}}
    end
  end

  def fetch(surface_kind), do: {:error, {:unsupported_surface_kind, surface_kind}}

  defp adapters do
    Enum.reduce(@optional_adapters, @base_adapters, fn {surface_kind, adapter}, acc ->
      if Code.ensure_loaded?(adapter) do
        Map.put(acc, surface_kind, adapter)
      else
        acc
      end
    end)
  end
end
