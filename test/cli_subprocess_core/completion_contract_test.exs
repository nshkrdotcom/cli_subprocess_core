defmodule CliSubprocessCore.CompletionContractTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.EphemeralFiles
  alias CliSubprocessCore.OutputSchemaFile
  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderProfiles.{Amp, Claude, Codex, Cursor}

  @schema %{
    "type" => "object",
    "properties" => %{"actions" => %{"type" => "array"}},
    "required" => ["actions"]
  }

  describe "structured output reaches the caller (PMX-F21)" do
    test "Payload.Result carries an object" do
      assert %Payload.Result{object: nil} = Payload.Result.new(status: :completed)
      assert %Payload.Result{object: %{"a" => 1}} = Payload.Result.new(object: %{"a" => 1})
    end

    test "the Claude decoder lifts structured_output onto the result" do
      state = Claude.init_parser_state(prompt: "hi", command: "claude")

      line =
        Jason.encode!(%{
          "type" => "result",
          "stop_reason" => "end_turn",
          "structured_output" => %{"actions" => [%{"index" => 0}]},
          "usage" => %{"input_tokens" => 3, "output_tokens" => 5}
        })

      assert {[event], _state} = Claude.decode_stdout(line, state)
      assert %Payload.Result{object: object} = event.payload
      assert object == %{"actions" => [%{"index" => 0}]}
    end

    test "the Claude decoder leaves object nil when no structured output is present" do
      state = Claude.init_parser_state(prompt: "hi", command: "claude")
      line = Jason.encode!(%{"type" => "result", "stop_reason" => "end_turn"})

      assert {[event], _state} = Claude.decode_stdout(line, state)
      assert %Payload.Result{object: nil} = event.payload
    end

    test "the Codex decoder lifts the schema-constrained final message" do
      state =
        Codex.init_parser_state(prompt: "hi", command: "codex", output_schema: @schema)

      message =
        Jason.encode!(%{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => ~s({"actions":[{"index":1}]})}
        })

      assert {_events, state} = Codex.decode_stdout(message, state)

      assert {[event], _state} =
               Codex.decode_stdout(Jason.encode!(%{"type" => "turn.completed"}), state)

      assert %Payload.Result{object: %{"actions" => [%{"index" => 1}]}} = event.payload
    end

    test "the Codex decoder does not invent an object without a requested schema" do
      state = Codex.init_parser_state(prompt: "hi", command: "codex")

      message =
        Jason.encode!(%{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => ~s({"actions":[]})}
        })

      assert {_events, state} = Codex.decode_stdout(message, state)

      assert {[event], _state} =
               Codex.decode_stdout(Jason.encode!(%{"type" => "turn.completed"}), state)

      assert %Payload.Result{object: nil} = event.payload
    end

    test "the Codex decoder leaves object nil when the reply is not JSON" do
      state = Codex.init_parser_state(prompt: "hi", command: "codex", output_schema: @schema)

      message =
        Jason.encode!(%{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => "sorry, no."}
        })

      assert {_events, state} = Codex.decode_stdout(message, state)

      assert {[event], _state} =
               Codex.decode_stdout(Jason.encode!(%{"type" => "turn.completed"}), state)

      assert %Payload.Result{object: nil} = event.payload
    end

    test "Amp and Cursor results declare the field explicitly" do
      amp_state = Amp.init_parser_state(prompt: "hi", command: "amp")

      assert {[event], _state} =
               Amp.decode_stdout(Jason.encode!(%{"type" => "result"}), amp_state)

      assert %Payload.Result{object: nil} = event.payload

      cursor_state = Cursor.init_parser_state(prompt: "hi", command: "cursor-agent")

      assert {[event], _state} =
               Cursor.decode_stdout(Jason.encode!(%{"type" => "result"}), cursor_state)

      assert %Payload.Result{object: nil} = event.payload
    end
  end

  describe "--output-schema is a file path (PMX-F07/F23)" do
    test "the Codex invocation passes a readable schema file, never inline JSON" do
      assert {:ok, %Command{} = command, teardown} =
               Codex.build_invocation(
                 command: "codex-bin",
                 prompt: "hi",
                 output_schema: @schema
               )

      assert index = Enum.find_index(command.args, &(&1 == "--output-schema"))
      path = Enum.at(command.args, index + 1)

      refute String.starts_with?(path, "{")
      assert File.regular?(path)
      assert Jason.decode!(File.read!(path)) == @schema

      assert teardown.() == :ok
      refute File.exists?(path)
    end

    test "no schema means no flag and no teardown" do
      assert {:ok, %Command{} = command} =
               Codex.build_invocation(command: "codex-bin", prompt: "hi")

      refute "--output-schema" in command.args
    end
  end

  describe "the schema file has an owner that outlives a brutal kill (D-17)" do
    test "the file is removed when its owner dies without running teardown" do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, path, _teardown} = OutputSchemaFile.create(@schema)
          send(parent, {:path, path})

          receive do
            :never -> :ok
          end
        end)

      # The spawn plus a GenServer call and a file write can exceed ExUnit's
      # 100 ms default on a loaded machine; this is a ceiling, not a delay.
      assert_receive {:path, path}, 10_000
      assert File.regular?(path)

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 10_000

      assert eventually(fn -> not File.exists?(path) end)
    end

    test "explicit teardown removes the file and stops tracking it" do
      assert {:ok, path, teardown} = OutputSchemaFile.create(@schema)
      assert EphemeralFiles.tracked?(path)
      assert teardown.() == :ok
      refute File.exists?(path)
      refute EphemeralFiles.tracked?(path)
      assert teardown.() == :ok
    end
  end

  describe "completion-only invocation (D-19)" do
    test "Claude receives an empty tool set, plan mode, no settings and no MCP" do
      assert {:ok, %Command{} = command} =
               Claude.build_invocation(
                 command: "claude-bin",
                 prompt: "hi",
                 completion_only: true
               )

      assert ["--tools", ""] == arg_pair(command.args, "--tools")
      assert ["--permission-mode", "plan"] == arg_pair(command.args, "--permission-mode")
      assert ["--setting-sources", ""] == arg_pair(command.args, "--setting-sources")
      assert "--strict-mcp-config" in command.args
      refute "--allowedTools" in command.args
    end

    test "completion-only overrides a caller-supplied write-capable permission mode" do
      assert {:ok, %Command{} = command} =
               Claude.build_invocation(
                 command: "claude-bin",
                 prompt: "hi",
                 completion_only: true,
                 permission_mode: :bypass_permissions
               )

      assert ["--permission-mode", "plan"] == arg_pair(command.args, "--permission-mode")
      refute "bypassPermissions" in command.args
    end

    test "Codex receives a read-only sandbox and never approvals" do
      assert {:ok, %Command{} = command} =
               Codex.build_invocation(
                 command: "codex-bin",
                 prompt: "hi",
                 completion_only: true
               )

      assert ["--sandbox", "read-only"] == arg_pair(command.args, "--sandbox")
      assert ~s(approval_policy="never") in command.args
      refute "--full-auto" in command.args
      refute "--dangerously-bypass-approvals-and-sandbox" in command.args
    end

    test "completion-only overrides a caller-supplied write-capable Codex mode" do
      assert {:ok, %Command{} = command} =
               Codex.build_invocation(
                 command: "codex-bin",
                 prompt: "hi",
                 completion_only: true,
                 permission_mode: :yolo
               )

      assert ["--sandbox", "read-only"] == arg_pair(command.args, "--sandbox")
      refute "--dangerously-bypass-approvals-and-sandbox" in command.args
    end

    test "ordinary invocations are unchanged" do
      assert {:ok, %Command{} = command} =
               Claude.build_invocation(command: "claude-bin", prompt: "hi")

      refute "--tools" in command.args
      refute "--strict-mcp-config" in command.args
    end
  end

  describe "transport reaping (PMX-F17)" do
    test "the declared headless timeout reaches the transport" do
      options =
        Codex.transport_options(
          prompt: "hi",
          command: "codex-bin",
          transport_headless_timeout_ms: 5_000
        )

      assert options[:headless_timeout_ms] == 5_000
    end

    test "an explicit transport key still wins" do
      options =
        Codex.transport_options(
          prompt: "hi",
          command: "codex-bin",
          headless_timeout_ms: 1_000,
          transport_headless_timeout_ms: 5_000
        )

      assert options[:headless_timeout_ms] == 1_000
    end
  end

  defp arg_pair(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      index -> Enum.slice(args, index, 2)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _attempt, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end
end
