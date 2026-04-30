defmodule CliSubprocessCore.ToolTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Tool
  alias CliSubprocessCore.Tool.{Descriptor, Request, Response}

  test "descriptor validates serializable metadata and preserves raw provider extras" do
    assert {:ok, descriptor} =
             Descriptor.parse(%{
               "name" => " shell ",
               "description" => "Run a command",
               "input_schema" => %{
                 "type" => "object",
                 "properties" => %{"cmd" => %{"type" => "string"}}
               },
               "provider_metadata" => %{"provider" => "codex"},
               "raw_provider_payload" => %{"tool" => %{"name" => "shell"}}
             })

    assert descriptor.name == "shell"
    assert descriptor.provider_metadata == %{"provider" => "codex"}
    assert descriptor.extra == %{"raw_provider_payload" => %{"tool" => %{"name" => "shell"}}}

    assert Descriptor.to_map(descriptor)["raw_provider_payload"] == %{
             "tool" => %{"name" => "shell"}
           }
  end

  test "request and response validate neutral serializable tool exchange data" do
    assert {:ok, request} =
             Request.parse(
               tool_name: "read_file",
               tool_call_id: "tool-1",
               input: %{"path" => "README.md"},
               provider_metadata: %{"provider" => "claude"}
             )

    assert request.tool_name == "read_file"
    assert request.input == %{"path" => "README.md"}

    assert {:ok, response} =
             Response.parse(
               tool_call_id: "tool-1",
               content: %{"ok" => true, "lines" => ["alpha"]},
               is_error: false
             )

    assert response.content == %{"ok" => true, "lines" => ["alpha"]}
  end

  test "tool data rejects executable BEAM handlers and runtime handles" do
    port = Port.open({:spawn, "cat"}, [:binary])

    invalid_terms = [
      fn -> :ok end,
      {String, :trim, 1},
      self(),
      port,
      make_ref(),
      :provider_builtin
    ]

    try do
      for invalid <- invalid_terms do
        assert {:error, {:invalid_tool, Descriptor, [error]}} =
                 Descriptor.parse(name: "bad", provider_metadata: %{"handler" => invalid})

        assert error.reason in [:serializable, :serializable_key]
        assert error.type in [:function, :tuple, :pid, :port, :reference, :atom]
      end
    after
      Port.close(port)
    end
  end

  test "tool data rejects non-string map keys inside serializable fields" do
    assert {:error, {:invalid_tool, Request, [error]}} =
             Request.parse(tool_name: "bad", tool_call_id: "tool-1", input: %{cmd: "pwd"})

    assert error.path == ["input", ":cmd"]
    assert error.reason == :serializable_key
    assert error.type == :atom
  end

  test "parse bang raises a stable invalid tool error" do
    assert_raise ArgumentError, ~r/invalid CliSubprocessCore.Tool.Response/, fn ->
      Response.parse!(tool_call_id: "tool-1", content: %{pid: self()})
    end
  end

  test "shared serializable validator accepts JSON-like data" do
    assert :ok =
             Tool.validate_serializable(%{
               "nil" => nil,
               "bool" => true,
               "number" => 1.5,
               "string" => "ok",
               "array" => [%{"nested" => false}]
             })
  end
end
