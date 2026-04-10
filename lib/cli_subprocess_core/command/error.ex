defmodule CliSubprocessCore.Command.Error do
  @moduledoc """
  Structured failures for the provider-aware non-PTY command lane.
  """

  alias ExecutionPlane.Process.Transport.Error, as: TransportError

  defexception [:reason, :message, context: %{}]

  @type reason ::
          {:invalid_options, term()}
          | {:provider_not_found, atom()}
          | {:command_plan_failed, term()}
          | {:transport, TransportError.t()}

  @type t :: %__MODULE__{
          reason: reason(),
          message: binary(),
          context: map()
        }

  @doc """
  Wraps invalid command-lane options.
  """
  def invalid_options(reason, context \\ %{}) when is_map(context) do
    %__MODULE__{
      reason: {:invalid_options, reason},
      message: "Invalid command options: #{inspect(reason)}",
      context: context
    }
  end

  @doc """
  Wraps provider lookup failure for provider-aware execution.
  """
  def provider_not_found(provider) when is_atom(provider) do
    %__MODULE__{
      reason: {:provider_not_found, provider},
      message: "Provider profile not found: #{inspect(provider)}",
      context: %{provider: provider}
    }
  end

  @doc """
  Wraps provider profile command construction failures.
  """
  def command_plan_failed(reason, context \\ %{}) when is_map(context) do
    %__MODULE__{
      reason: {:command_plan_failed, reason},
      message: "Failed to build command invocation: #{inspect(reason)}",
      context: context
    }
  end

  @doc """
  Wraps a transport-layer execution failure.
  """
  @spec transport_error(TransportError.t(), map()) :: t()
  def transport_error(%TransportError{} = error, context \\ %{}) when is_map(context) do
    %__MODULE__{
      reason: {:transport, error},
      message: error.message,
      context: Map.merge(error.context, context)
    }
  end
end
