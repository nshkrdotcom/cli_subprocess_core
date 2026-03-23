defmodule CliSubprocessCore do
  @moduledoc """
  Public entrypoints for the shared CLI subprocess runtime foundation.
  """

  alias CliSubprocessCore.{Event, ProviderRegistry}

  @type first_party_profile_module ::
          CliSubprocessCore.ProviderProfiles.Claude
          | CliSubprocessCore.ProviderProfiles.Codex
          | CliSubprocessCore.ProviderProfiles.Gemini
          | CliSubprocessCore.ProviderProfiles.Amp

  @first_party_profile_modules [
    CliSubprocessCore.ProviderProfiles.Claude,
    CliSubprocessCore.ProviderProfiles.Codex,
    CliSubprocessCore.ProviderProfiles.Gemini,
    CliSubprocessCore.ProviderProfiles.Amp
  ]

  @doc """
  Returns the first-party provider profile modules shipped by
  `cli_subprocess_core`.
  """
  @spec first_party_profile_modules() :: [first_party_profile_module(), ...]
  def first_party_profile_modules, do: @first_party_profile_modules

  @doc """
  Returns provider profile modules configured to preload into the default
  registry at boot.
  """
  @spec configured_profile_modules() :: [module()]
  def configured_profile_modules do
    Application.get_env(:cli_subprocess_core, :built_in_profile_modules, [])
  end

  @doc """
  Returns the provider profile modules booted into the default registry.

  This includes the shipped first-party profiles plus any explicitly configured
  external preload modules.
  """
  @spec built_in_profile_modules() :: [module()]
  def built_in_profile_modules do
    (first_party_profile_modules() ++ configured_profile_modules())
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
