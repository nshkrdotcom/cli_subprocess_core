defmodule CliSubprocessCore do
  @moduledoc """
  Public entrypoints for the shared CLI subprocess runtime foundation.
  """

  alias CliSubprocessCore.{Event, ProviderRegistry}

  @default_built_in_profile_modules [
    CliSubprocessCore.ProviderProfiles.Claude,
    CliSubprocessCore.ProviderProfiles.Codex,
    CliSubprocessCore.ProviderProfiles.Gemini,
    CliSubprocessCore.ProviderProfiles.Amp
  ]

  @doc """
  Returns the configured built-in provider profile modules.
  """
  @spec built_in_profile_modules() :: [module()]
  def built_in_profile_modules do
    (@default_built_in_profile_modules ++
       Application.get_env(:cli_subprocess_core, :built_in_profile_modules, []))
    |> Enum.uniq()
  end

  @doc """
  Returns the normalized event kinds exposed by the core vocabulary.
  """
  @spec normalized_event_kinds() :: [Event.kind()]
  def normalized_event_kinds do
    Event.kinds()
  end

  @doc """
  Resolves a provider profile from the default registry.
  """
  @spec provider_profile(atom()) :: {:ok, module()} | :error
  def provider_profile(id) when is_atom(id) do
    ProviderRegistry.fetch(id)
  end
end
