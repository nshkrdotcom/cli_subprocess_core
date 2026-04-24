defmodule CliSubprocessCore.ProcessExitTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ProcessExit

  describe "facade helpers" do
    test "normalizes and projects successful exits" do
      exit = ProcessExit.from_reason(:normal)

      assert ProcessExit.match?(exit)
      assert ProcessExit.successful?(exit)
      assert ProcessExit.status(exit) == :success
      assert ProcessExit.code(exit) == 0
      assert ProcessExit.reason(exit) == :normal
      assert ProcessExit.to_map(exit).status == :success
    end

    test "returns nil-safe values for non-exit terms" do
      refute ProcessExit.match?(:bad_exit)
      refute ProcessExit.successful?(:bad_exit)
      assert ProcessExit.status(:bad_exit) == nil
      assert ProcessExit.code(:bad_exit) == nil
      assert ProcessExit.signal(:bad_exit) == nil
      assert ProcessExit.stderr(:bad_exit) == nil
      assert ProcessExit.reason(:bad_exit) == :bad_exit
    end
  end
end
