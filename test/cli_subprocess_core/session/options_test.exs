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

  test "rejects public transport_module selection" do
    assert {:error, {:unsupported_option, :transport_module}} =
             Options.new(
               provider: :echo,
               prompt: "hello",
               transport_module: CliSubprocessCore.Transport
             )
  end
end
