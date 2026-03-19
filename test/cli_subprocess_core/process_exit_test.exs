defmodule CliSubprocessCore.ProcessExitTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ProcessExit

  test "normalizes successful exits" do
    exit = ProcessExit.from_reason(:normal)

    assert exit.status == :success
    assert exit.code == 0
    assert ProcessExit.successful?(exit)
  end

  test "normalizes non-zero exit statuses" do
    exit = ProcessExit.from_reason({:exit_status, 17})

    assert exit.status == :exit
    assert exit.code == 17
    refute ProcessExit.successful?(exit)
  end

  test "normalizes signal exits wrapped by shutdown" do
    exit = ProcessExit.from_reason({:shutdown, {:signal, :sigterm}})

    assert exit.status == :signal
    assert exit.signal == :sigterm
    refute ProcessExit.successful?(exit)
  end

  test "preserves unknown reasons as errors" do
    exit = ProcessExit.from_reason(:killed)

    assert exit.status == :error
    assert exit.reason == :killed
  end
end
