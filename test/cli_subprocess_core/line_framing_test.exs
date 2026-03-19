defmodule CliSubprocessCore.LineFramingTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.LineFraming

  test "frames newline-delimited stdout incrementally" do
    state = LineFraming.new()

    assert {["alpha"], state} = LineFraming.push(state, "alpha\nbeta")
    assert state.buffer == "beta"

    assert {["beta", "gamma"], state} = LineFraming.push(state, "\r\ngamma\rdelta")
    assert state.buffer == "delta"

    assert {["delta"], state} = LineFraming.flush(state)
    assert LineFraming.empty?(state)
  end

  test "handles blank lines and a crlf sequence split across chunks" do
    state = LineFraming.new()

    assert {[], state} = LineFraming.push(state, "one\r")
    assert {["one", "", "two", ""], state} = LineFraming.push(state, "\n\r\ntwo\n\nthree")
    assert state.buffer == "three"

    assert {["three"], _state} = LineFraming.flush(state)
  end
end
