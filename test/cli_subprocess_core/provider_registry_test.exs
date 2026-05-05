defmodule CliSubprocessCore.ProviderRegistryTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ProviderRegistry
  alias CliSubprocessCore.TestSupport.ProviderProfiles.{Alternate, DuplicateEcho, Echo}

  setup do
    registry = start_supervised!({ProviderRegistry, profile_modules: [Echo]})

    %{registry: registry}
  end

  test "loads built-in profile modules on start", %{registry: registry} do
    assert [Echo] == ProviderRegistry.built_in_modules(registry)
    assert [:echo] == ProviderRegistry.ids(registry)
    assert {:ok, Echo} == ProviderRegistry.fetch(:echo, registry)
    assert ProviderRegistry.registered?(:echo, registry)
  end

  test "registers additional profile modules after start", %{registry: registry} do
    assert :ok == ProviderRegistry.register(Alternate, registry)
    assert {:ok, Alternate} == ProviderRegistry.fetch(:alternate, registry)
    assert Enum.sort(ProviderRegistry.ids(registry)) == [:alternate, :echo]
    assert ProviderRegistry.built_in_modules(registry) == [Echo]
  end

  test "rejects duplicate profile ids for different modules", %{registry: registry} do
    assert {:error, {:duplicate_profile_id, :echo, Echo, DuplicateEcho}} ==
             ProviderRegistry.register(DuplicateEcho, registry)
  end
end
