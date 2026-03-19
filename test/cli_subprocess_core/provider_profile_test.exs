defmodule CliSubprocessCore.ProviderProfileTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ProviderProfile
  alias CliSubprocessCore.TestSupport.ProviderProfiles.{Echo, Invalid}

  test "accepts modules that implement the provider profile contract" do
    assert :ok == ProviderProfile.ensure_module(Echo)
  end

  test "rejects modules that do not implement the contract" do
    assert {:error, {:missing_callbacks, Invalid, missing}} =
             ProviderProfile.ensure_module(Invalid)

    assert {:capabilities, 0} in missing
    assert {:build_invocation, 1} in missing
    assert {:decode_stdout, 2} in missing
  end

  test "validates invocations returned from profiles" do
    assert {:ok, invocation} = Echo.build_invocation(cwd: "/tmp/echo")
    assert :ok == ProviderProfile.validate_invocation(invocation)
  end
end
