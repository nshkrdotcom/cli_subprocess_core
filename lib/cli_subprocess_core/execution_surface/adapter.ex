defmodule CliSubprocessCore.ExecutionSurface.Adapter do
  @moduledoc """
  Internal behaviour for execution-surface adapters owned by the core.
  """

  alias CliSubprocessCore.ExecutionSurface
  alias CliSubprocessCore.ExecutionSurface.Capabilities

  @type normalized_transport_options :: keyword()

  @callback surface_kind() :: ExecutionSurface.surface_kind()
  @callback capabilities() :: Capabilities.t()
  @callback normalize_transport_options(term()) ::
              {:ok, normalized_transport_options()}
              | {:error, {:invalid_transport_options, term()}}
end
