defmodule CliSubprocessCore.ProviderFeatures.Error do
  @moduledoc """
  Typed failure returned when a built-in provider cannot honor a requested
  common feature.

  Callers may pattern-match `provider`, `feature`, `option`, and
  `support_state` without parsing prose.
  """

  defexception [:provider, :feature, :option, :support_state]

  @type support_state :: :unsupported | :unknown

  @type t :: %__MODULE__{
          provider: atom(),
          feature: atom(),
          option: atom(),
          support_state: support_state()
        }

  @impl Exception
  def message(%__MODULE__{} = error) do
    "provider #{inspect(error.provider)} cannot honor #{inspect(error.option)} " <>
      "(feature #{inspect(error.feature)} is #{error.support_state})"
  end
end
