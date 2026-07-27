defmodule CliSubprocessCore.CompletionContractTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.EphemeralFile
  alias CliSubprocessCore.EphemeralFiles
  alias CliSubprocessCore.OutputSchemaFile
  alias CliSubprocessCore.Payload
  alias CliSubprocessCore.ProviderFeatures
  alias CliSubprocessCore.ProviderFeatures.Error, as: ProviderFeatureError
  alias CliSubprocessCore.ProviderProfiles.{Amp, Antigravity, Claude, Codex, Cursor}
  alias CliSubprocessCore.Session

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

  describe "structured output is a declared per-provider capability (PMX-F25)" do
    test "Claude takes the schema as inline JSON on --json-schema" do
      assert {:ok, %Command{} = command} =
               Claude.build_invocation(
                 command: "claude-bin",
                 prompt: "hi",
                 output_schema: @schema
               )

      assert ["--json-schema", encoded] = arg_pair(command.args, "--json-schema")
      assert Jason.decode!(encoded) == @schema
    end

    test "both CLI providers declare the capability, with their real wire form" do
      assert {:ok, claude} = ProviderFeatures.partial_feature(:claude, :structured_output)
      assert claude.supported?
      assert claude.compatibility.wire_form == :inline_json
      assert claude.compatibility.cli_flag == "--json-schema"

      assert {:ok, codex} = ProviderFeatures.partial_feature(:codex, :structured_output)
      assert codex.supported?
      assert codex.compatibility.wire_form == :file_path
      assert codex.compatibility.cli_flag == "--output-schema"
    end

    test "every built-in provider declares structured-output support explicitly" do
      for provider <- [:amp, :antigravity, :claude, :codex, :cursor] do
        assert {:ok, %{supported?: supported?}} =
                 ProviderFeatures.partial_feature(provider, :structured_output)

        assert is_boolean(supported?)
      end

      refute ProviderFeatures.partial_feature!(:cursor, :structured_output).supported?
      refute ProviderFeatures.partial_feature!(:amp, :structured_output).supported?
      refute ProviderFeatures.partial_feature!(:antigravity, :structured_output).supported?
    end

    test "Amp and Antigravity reject schema intent with a typed error before resolution" do
      for profile <- [Amp, Antigravity] do
        assert {:error,
                %ProviderFeatureError{
                  feature: :structured_output,
                  option: :output_schema,
                  support_state: :unsupported
                }} =
                 profile.build_invocation(
                   command: "/definitely/not/a/provider",
                   prompt: "hi",
                   output_schema: @schema
                 )
      end
    end
  end

  describe "the schema file has an owner that outlives a brutal kill (D-17)" do
    test "the generic primitive writes one exclusive owner-only file" do
      assert {:ok, path, teardown} =
               EphemeralFile.create(["encoded", "-", "settings"],
                 prefix: "amp_sdk_settings",
                 suffix: ".json"
               )

      assert Path.dirname(path) == System.tmp_dir!()
      assert Path.basename(path) =~ "amp_sdk_settings_"
      assert String.ends_with?(path, ".json")
      assert File.read!(path) == "encoded-settings"
      assert {:ok, stat} = File.stat(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600
      assert EphemeralFiles.tracked?(path)

      assert teardown.() == :ok
      assert teardown.() == :ok
      refute File.exists?(path)
      refute EphemeralFiles.tracked?(path)
    end

    test "the generic primitive rejects path-like names" do
      assert {:error, :invalid_ephemeral_file_name} =
               EphemeralFile.create("payload", prefix: "../directory")

      assert {:error, :invalid_ephemeral_file_name} =
               EphemeralFile.create("payload", suffix: "/settings.json")
    end

    test "the generic primitive removes its file when the owner is killed" do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, path, _teardown} = EphemeralFile.create("settings", prefix: "owner_kill")
          send(parent, {:generic_path, path})
          Process.sleep(:infinity)
        end)

      assert_receive {:generic_path, path}, 10_000
      assert File.regular?(path)

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 10_000
      assert eventually(fn -> not File.exists?(path) end)
    end

    test "the file name is namespaced across BEAM VMs and is owner-only" do
      assert {:ok, path, teardown} = OutputSchemaFile.create(@schema)
      assert Path.basename(path) =~ "_#{System.pid()}_"
      assert {:ok, stat} = File.stat(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600
      assert teardown.() == :ok
    end

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

    test "the tracker rejects a path already owned by another process" do
      tracker = :"ephemeral_files_#{System.unique_integer([:positive])}"
      start_supervised!({EphemeralFiles, name: tracker})

      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      path =
        Path.join(
          System.tmp_dir!(),
          "ephemeral_files_duplicate_#{System.unique_integer([:positive])}"
        )

      assert :ok = EphemeralFiles.track(path, owner, tracker)
      assert {:error, :path_already_tracked} = EphemeralFiles.track(path, self(), tracker)

      send(owner, :stop)
    end

    test "the command API removes schema files after success and transport error" do
      success = create_test_script("exit 0")

      assert {:ok, result} =
               Command.run(
                 provider: :codex,
                 command: success,
                 prompt: "hi",
                 output_schema: @schema
               )

      success_path = output_schema_path(result.invocation.args)
      refute File.exists?(success_path)
      refute EphemeralFiles.tracked?(success_path)

      missing_cwd = temp_path!("missing_cwd")

      assert {:error, error} =
               Command.run(
                 provider: :codex,
                 command: success,
                 cwd: missing_cwd,
                 prompt: "hi",
                 output_schema: @schema
               )

      failure_path = output_schema_path(error.context.invocation.args)
      refute File.exists?(failure_path)
      refute EphemeralFiles.tracked?(failure_path)
    end

    test "the session API removes schema files on result, error, interrupt, close, and kill" do
      assert_session_schema_cleanup(:result)
      assert_session_schema_cleanup(:error)
      assert_session_schema_cleanup(:interrupt)
      assert_session_schema_cleanup(:close)
      assert_session_schema_cleanup(:kill)
    end
  end

  describe "completion-only invocation (D-19)" do
    test "every built-in provider declares completion-only support explicitly" do
      for provider <- [:amp, :antigravity, :claude, :codex, :cursor] do
        assert {:ok, %{supported?: supported?}} =
                 ProviderFeatures.partial_feature(provider, :completion_only)

        assert is_boolean(supported?)
      end

      assert ProviderFeatures.partial_feature!(:claude, :completion_only).supported?
      assert ProviderFeatures.partial_feature!(:codex, :completion_only).supported?
      refute ProviderFeatures.partial_feature!(:cursor, :completion_only).supported?
      refute ProviderFeatures.partial_feature!(:amp, :completion_only).supported?
      refute ProviderFeatures.partial_feature!(:antigravity, :completion_only).supported?
    end

    test "Amp and Antigravity reject completion-only intent before resolution" do
      for profile <- [Amp, Antigravity] do
        assert {:error,
                %ProviderFeatureError{
                  provider: provider,
                  feature: :completion_only,
                  option: :completion_only,
                  support_state: :unsupported
                }} =
                 profile.build_invocation(
                   command: "/definitely/not/a/provider",
                   prompt: "hi",
                   completion_only: true
                 )

        assert provider == profile.id()
      end
    end

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

    test "Codex receives an isolated read-only, tool-free configuration" do
      assert {:ok, %Command{} = command} =
               Codex.build_invocation(
                 command: "codex-bin",
                 prompt: "hi",
                 completion_only: true
               )

      assert ["--sandbox", "read-only"] == arg_pair(command.args, "--sandbox")
      assert "--ephemeral" in command.args
      assert "--ignore-user-config" in command.args
      assert "--ignore-rules" in command.args
      assert ~s(approval_policy="never") in command.args
      assert ~s(web_search="disabled") in command.args
      assert "skills.include_instructions=false" in command.args
      assert "skills.bundled.enabled=false" in command.args
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
      assert "--ephemeral" in command.args
      assert "--ignore-user-config" in command.args
      assert "--ignore-rules" in command.args
      refute "--dangerously-bypass-approvals-and-sandbox" in command.args
    end

    test "Codex completion-only discards caller and payload config overrides" do
      assert {:ok, %Command{} = command} =
               Codex.build_invocation(
                 command: "codex-bin",
                 prompt: "return an object",
                 completion_only: true,
                 config_values: [
                   ~s(approval_policy="on-request"),
                   ~s(web_search="live"),
                   "skills.include_instructions=true",
                   "mcp_servers.host.command=\"unsafe\""
                 ],
                 backend_payload: %{
                   "config_values" => [
                     "skills.bundled.enabled=true",
                     "mcp_servers.payload.command=\"unsafe\""
                   ]
                 }
               )

      config_values = repeated_values(command.args, "--config")

      assert ~s(approval_policy="never") in config_values
      assert ~s(web_search="disabled") in config_values
      assert "skills.include_instructions=false" in config_values
      assert "skills.bundled.enabled=false" in config_values
      refute Enum.any?(config_values, &String.contains?(&1, "unsafe"))
      refute ~s(approval_policy="on-request") in config_values
      refute ~s(web_search="live") in config_values
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

  defp repeated_values(args, flag) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [^flag, value] -> [value]
      _other -> []
    end)
  end

  defp assert_session_schema_cleanup(terminal_path) do
    gate = temp_path!("schema_cleanup_gate")
    ready = temp_path!("schema_cleanup_ready")

    terminal_command =
      case terminal_path do
        :result -> ~s(printf '{"type":"turn.completed"}\\n')
        :error -> "exit 23"
        path when path in [:interrupt, :close, :kill] -> "sleep 60"
      end

    script =
      create_test_script("""
      touch "#{ready}"
      while [ ! -f "#{gate}" ]; do sleep 0.01; done
      #{terminal_command}
      """)

    assert {:ok, session, info} =
             Session.start_session(
               provider: :codex,
               command: script,
               prompt: "hi",
               output_schema: @schema
             )

    path = output_schema_path(info.invocation.args)
    assert File.regular?(path)
    assert EphemeralFiles.tracked?(path)
    assert eventually(fn -> File.exists?(ready) end, 1_000)

    monitor = Process.monitor(session)

    case terminal_path do
      path when path in [:result, :error] ->
        File.write!(gate, "go")

      :interrupt ->
        File.write!(gate, "go")
        assert :ok = Session.interrupt(session)

      :close ->
        assert :ok = Session.close(session)

      :kill ->
        Process.exit(session, :kill)
    end

    expected_reason = if terminal_path == :kill, do: :killed, else: :normal
    assert_receive {:DOWN, ^monitor, :process, ^session, ^expected_reason}, 10_000
    assert eventually(fn -> not File.exists?(path) end)
    refute EphemeralFiles.tracked?(path)
  end

  defp output_schema_path(args) do
    args
    |> arg_pair("--output-schema")
    |> List.last()
  end

  defp create_test_script(body) do
    dir = temp_path!("completion_contract")
    File.mkdir_p!(dir)
    path = Path.join(dir, "fixture.sh")

    File.write!(path, """
    #!/usr/bin/env bash
    set -euo pipefail
    #{body}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp temp_path!(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{name}_#{System.pid()}_#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(path) end)
    path
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
