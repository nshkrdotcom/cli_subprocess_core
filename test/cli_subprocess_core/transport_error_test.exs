defmodule CliSubprocessCore.TransportErrorTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.TransportError

  describe "facade helpers" do
    test "builds and projects transport errors" do
      error = TransportError.transport_error(:timeout, %{operation: :run})

      assert TransportError.match?(error)
      assert TransportError.reason(error) == :timeout
      assert TransportError.message(error) == "Transport timeout"
      assert TransportError.context(error) == %{operation: :run}

      assert TransportError.to_map(error) == %{
               reason: :timeout,
               message: "Transport timeout",
               context: %{operation: :run}
             }
    end

    test "returns fallback values for non-error terms" do
      refute TransportError.match?(:timeout)
      assert TransportError.reason(:timeout) == :timeout
      assert TransportError.message(:timeout) == ":timeout"
      assert TransportError.context(:timeout) == %{}
    end
  end
end
