defmodule CliSubprocessCoreTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ProviderProfiles

  test "first_party_profile_modules/0 exposes the shipped Phase 2B core profiles" do
    assert CliSubprocessCore.first_party_profile_modules() == [
             ProviderProfiles.Claude,
             ProviderProfiles.Codex,
             ProviderProfiles.Gemini,
             ProviderProfiles.Amp
           ]
  end

  test "built_in_profile_modules/0 remains the boot registry preload list" do
    Application.put_env(:cli_subprocess_core, :built_in_profile_modules, [
      CliSubprocessCore.TestSupport.ProviderProfiles.Echo
    ])

    on_exit(fn -> Application.delete_env(:cli_subprocess_core, :built_in_profile_modules) end)

    assert CliSubprocessCore.built_in_profile_modules() == [
             ProviderProfiles.Claude,
             ProviderProfiles.Codex,
             ProviderProfiles.Gemini,
             ProviderProfiles.Amp,
             CliSubprocessCore.TestSupport.ProviderProfiles.Echo
           ]
  end
end
