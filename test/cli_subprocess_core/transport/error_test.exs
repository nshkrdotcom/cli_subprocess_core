defmodule CliSubprocessCore.Transport.ErrorTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Transport.Error

  test "builds generic transport errors" do
    error = Error.transport_error(:timeout, %{operation: :send})

    assert error.reason == :timeout
    assert error.context == %{operation: :send}
    assert error.message =~ "timeout"
  end

  test "builds buffer overflow errors with context" do
    error = Error.buffer_overflow(4_096, 1_024, "preview")

    assert error.reason == {:buffer_overflow, 4_096, 1_024}
    assert error.context.preview == "preview"
    assert error.context.actual_size == 4_096
    assert error.context.max_size == 1_024
  end

  test "builds command-not-found errors" do
    error = Error.command_not_found("/tmp/missing")

    assert error.reason == {:command_not_found, "/tmp/missing"}
    assert error.message =~ "/tmp/missing"
  end
end
