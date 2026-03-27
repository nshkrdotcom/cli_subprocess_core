defmodule CliSubprocessCore.Session.OptionsTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Session.Options
  alias CliSubprocessCore.TestSupport.ProviderProfiles.Echo

  test "derives the provider id from an explicit profile" do
    assert {:ok, %Options{} = options} =
             Options.new(
               profile: Echo,
               subscriber: {self(), make_ref()},
               metadata: %{lane: :core},
               prompt: "hello"
             )

    assert options.provider == :echo
    assert options.profile == Echo
    assert options.metadata == %{lane: :core}
    assert options.provider_options == [prompt: "hello"]
  end

  test "rejects missing provider and profile" do
    assert {:error, :missing_provider} == Options.new(prompt: "hello")
  end

  test "rejects invalid subscriber shapes" do
    assert {:error, {:invalid_subscriber, {:not_a_pid, :legacy}}} =
             Options.new(provider: :echo, subscriber: {:not_a_pid, :legacy})
  end

  test "reserves execution-surface input off the provider lane" do
    assert {:ok, %Options{} = options} =
             Options.new(
               provider: :echo,
               prompt: "hello",
               surface_kind: :local_subprocess,
               target_id: "target-1",
               lease_ref: "lease-1",
               surface_ref: "surface-1",
               boundary_class: :local,
               observability: %{suite: :phase_b},
               transport_options: [startup_mode: :lazy]
             )

    assert options.provider_options == [prompt: "hello"]
    assert options.surface_kind == :local_subprocess
    assert options.target_id == "target-1"
    assert options.lease_ref == "lease-1"
    assert options.surface_ref == "surface-1"
    assert options.boundary_class == :local
    assert options.observability == %{suite: :phase_b}
    assert options.transport_options == [startup_mode: :lazy]
  end

  test "rejects public transport-selector overrides" do
    assert {:error, {:unsupported_option, :transport_selector}} =
             Options.new(
               provider: :echo,
               prompt: "hello",
               transport_module: CliSubprocessCore.Transport
             )
  end
end
