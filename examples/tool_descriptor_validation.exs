descriptor =
  CliSubprocessCore.Tool.Descriptor.new(
    name: "read_file",
    description: "Read a UTF-8 text file",
    input_schema: %{
      "type" => "object",
      "required" => ["path"],
      "properties" => %{
        "path" => %{"type" => "string"}
      }
    },
    provider_metadata: %{
      "owner" => "example"
    }
  )

request =
  CliSubprocessCore.Tool.Request.new(
    tool_name: descriptor.name,
    tool_call_id: "tool-1",
    input: %{"path" => "README.md"}
  )

response =
  CliSubprocessCore.Tool.Response.new(
    tool_call_id: request.tool_call_id,
    content: %{"ok" => true}
  )

IO.inspect(CliSubprocessCore.Tool.Descriptor.to_map(descriptor), label: "descriptor")
IO.inspect(CliSubprocessCore.Tool.Request.to_map(request), label: "request")
IO.inspect(CliSubprocessCore.Tool.Response.to_map(response), label: "response")
