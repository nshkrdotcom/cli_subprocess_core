defmodule CliSubprocessCore.ProviderCLITest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.CommandSpec
  alias CliSubprocessCore.ProviderCLI
  alias CliSubprocessCore.ProviderCLI.Error
  alias CliSubprocessCore.ProviderCLI.ErrorRuntimeFailure
  alias CliSubprocessCore.TestSupport
  alias ExternalRuntimeTransport.ProcessExit

  defp isolated_env(overrides \\ %{}) do
    Map.merge(
      %{
        "GEMINI_CLI_PATH" => nil,
        "PATH" => "/nonexistent_dir_only",
        "GEMINI_NO_NPX" => "1"
      },
      overrides
    )
  end

  describe "resolve/3 for Gemini" do
    test "finds gemini via GEMINI_CLI_PATH env var" do
      dir = TestSupport.tmp_dir!("core_gemini_cli")
      gemini_path = TestSupport.write_executable!(dir, "gemini", "#!/bin/bash\nexit 0\n")

      try do
        TestSupport.with_env(%{"GEMINI_CLI_PATH" => gemini_path}, fn ->
          assert {:ok, %CommandSpec{program: ^gemini_path, argv_prefix: []}} =
                   ProviderCLI.resolve(:gemini)
        end)
      after
        File.rm_rf(dir)
      end
    end

    test "returns error for nonexistent GEMINI_CLI_PATH" do
      TestSupport.with_env(%{"GEMINI_CLI_PATH" => "/nonexistent/gemini"}, fn ->
        assert {:error, %Error{kind: :cli_not_found} = error} = ProviderCLI.resolve(:gemini)
        assert error.message =~ "GEMINI_CLI_PATH points to non-existent file"
      end)
    end

    test "returns error for non-executable GEMINI_CLI_PATH" do
      dir = TestSupport.tmp_dir!("core_gemini_cli_non_exec")
      non_exec = TestSupport.write_file!(dir, "gemini", "echo hi\n")

      try do
        TestSupport.with_env(%{"GEMINI_CLI_PATH" => non_exec}, fn ->
          assert {:error, %Error{kind: :cli_not_found} = error} = ProviderCLI.resolve(:gemini)
          assert error.message =~ "GEMINI_CLI_PATH points to non-executable file"
        end)
      after
        File.rm_rf(dir)
      end
    end

    test "finds gemini in PATH when env var is not set" do
      dir = TestSupport.tmp_dir!("core_gemini_cli_path")
      gemini_path = TestSupport.write_executable!(dir, "gemini", "#!/bin/bash\nexit 0\n")
      path = dir <> ":" <> (System.get_env("PATH") || "")

      try do
        TestSupport.with_env(%{"GEMINI_CLI_PATH" => nil, "PATH" => path}, fn ->
          assert {:ok, %CommandSpec{program: ^gemini_path, argv_prefix: []}} =
                   ProviderCLI.resolve(:gemini)
        end)
      after
        File.rm_rf(dir)
      end
    end

    test "finds gemini in npm global prefix bin directory" do
      npm_dir = TestSupport.tmp_dir!("core_gemini_npm_bin")
      prefix_dir = TestSupport.tmp_dir!("core_gemini_prefix")
      bin_dir = Path.join(prefix_dir, "bin")
      File.mkdir_p!(bin_dir)
      gemini_path = TestSupport.write_executable!(bin_dir, "gemini", "#!/bin/bash\nexit 0\n")

      TestSupport.write_executable!(npm_dir, "npm", "#!/bin/bash\necho '#{prefix_dir}'\n")
      path = npm_dir <> ":/nonexistent_dir_only"

      try do
        TestSupport.with_env(isolated_env(%{"PATH" => path}), fn ->
          assert {:ok, %CommandSpec{program: ^gemini_path}} = ProviderCLI.resolve(:gemini)
        end)
      after
        File.rm_rf(npm_dir)
        File.rm_rf(prefix_dir)
      end
    end

    test "falls back to npx when gemini is not on PATH or in npm global" do
      npx_dir = TestSupport.tmp_dir!("core_gemini_npx")
      npx_path = TestSupport.write_executable!(npx_dir, "npx", "#!/bin/bash\nexit 0\n")
      path = npx_dir <> ":/nonexistent_dir_only"

      try do
        TestSupport.with_env(
          %{
            "GEMINI_CLI_PATH" => nil,
            "PATH" => path,
            "GEMINI_NO_NPX" => nil
          },
          fn ->
            assert {:ok,
                    %CommandSpec{
                      program: ^npx_path,
                      argv_prefix: ["--yes", "--package", "@google/gemini-cli", "gemini"]
                    }} = ProviderCLI.resolve(:gemini)
          end
        )
      after
        File.rm_rf(npx_dir)
      end
    end

    test "npx fallback is disabled when GEMINI_NO_NPX=1" do
      npx_dir = TestSupport.tmp_dir!("core_gemini_npx_disabled")
      TestSupport.write_executable!(npx_dir, "npx", "#!/bin/bash\nexit 0\n")
      path = npx_dir <> ":/nonexistent_dir_only"

      try do
        TestSupport.with_env(
          %{
            "GEMINI_CLI_PATH" => nil,
            "PATH" => path,
            "GEMINI_NO_NPX" => "1"
          },
          fn ->
            assert {:error, %Error{kind: :cli_not_found}} = ProviderCLI.resolve(:gemini)
          end
        )
      after
        File.rm_rf(npx_dir)
      end
    end

    test "returns an error when gemini is unavailable everywhere" do
      TestSupport.with_env(isolated_env(), fn ->
        assert {:error, %Error{kind: :cli_not_found} = error} = ProviderCLI.resolve(:gemini)
        assert error.message =~ "Gemini CLI not found"
      end)
    end
  end

  describe "resolve/3 for other built-in providers" do
    test "Codex honors CODEX_PATH" do
      dir = TestSupport.tmp_dir!("core_codex_cli")
      codex_path = TestSupport.write_executable!(dir, "codex", "#!/bin/bash\nexit 0\n")

      try do
        TestSupport.with_env(%{"CODEX_PATH" => codex_path}, fn ->
          assert {:ok, %CommandSpec{program: ^codex_path, argv_prefix: []}} =
                   ProviderCLI.resolve(:codex)
        end)
      after
        File.rm_rf(dir)
      end
    end

    test "Codex stabilizes asdf shims discovered through PATH" do
      {root, shim_path, resolved_path} = build_fake_asdf_codex()
      path = Path.dirname(shim_path) <> ":/nonexistent_dir_only"

      try do
        TestSupport.with_env(%{"PATH" => path, "ASDF_DIR" => Path.join(root, ".asdf")}, fn ->
          assert {:ok, %CommandSpec{program: ^resolved_path, argv_prefix: []}} =
                   ProviderCLI.resolve(:codex, [], resolution_cwd: root)
        end)
      after
        File.rm_rf(root)
      end
    end

    test "Codex stabilizes explicit asdf shim overrides" do
      {root, shim_path, resolved_path} = build_fake_asdf_codex()

      try do
        TestSupport.with_env(%{"ASDF_DIR" => Path.join(root, ".asdf")}, fn ->
          assert {:ok, %CommandSpec{program: ^resolved_path, argv_prefix: []}} =
                   ProviderCLI.resolve(:codex, command: shim_path, resolution_cwd: root)
        end)
      after
        File.rm_rf(root)
      end
    end

    test "Codex stabilizes shebang launchers that depend on node shims" do
      {root, shim_path, script_path, node_path} = build_fake_asdf_codex_js()
      path = Path.dirname(shim_path) <> ":/nonexistent_dir_only"

      try do
        TestSupport.with_env(%{"PATH" => path, "ASDF_DIR" => Path.join(root, ".asdf")}, fn ->
          assert {:ok, %CommandSpec{program: ^node_path, argv_prefix: [^script_path]}} =
                   ProviderCLI.resolve(:codex, [], resolution_cwd: root)
        end)
      after
        File.rm_rf(root)
      end
    end

    test "Codex does not misclassify installed interpreters when their contents mention a manager command" do
      {root, script_path, node_path} = build_fake_codex_with_non_shim_node_marker()
      path = Path.dirname(node_path) <> ":/nonexistent_dir_only"

      try do
        TestSupport.with_env(%{"HOME" => root, "PATH" => path, "MISE_BIN" => nil}, fn ->
          assert {:ok, %CommandSpec{} = spec} = ProviderCLI.resolve(:codex, command: script_path)
          assert spec.program in [script_path, node_path]

          case spec.program do
            ^script_path -> assert spec.argv_prefix == []
            ^node_path -> assert spec.argv_prefix == [script_path]
          end
        end)
      after
        File.rm_rf(root)
      end
    end

    test "Amp honors AMP_CLI_PATH" do
      dir = TestSupport.tmp_dir!("core_amp_cli")
      amp_path = TestSupport.write_executable!(dir, "amp", "#!/bin/bash\nexit 0\n")

      try do
        TestSupport.with_env(%{"AMP_CLI_PATH" => amp_path}, fn ->
          assert {:ok, %CommandSpec{program: ^amp_path, argv_prefix: []}} =
                   ProviderCLI.resolve(:amp)
        end)
      after
        File.rm_rf(dir)
      end
    end

    test "Amp wraps JavaScript launchers from AMP_CLI_PATH with node" do
      dir = TestSupport.tmp_dir!("core_amp_cli_js")
      js_path = TestSupport.write_file!(dir, "amp.js", "console.log('amp');\n")
      node_path = TestSupport.write_executable!(dir, "node", "#!/bin/bash\nexit 0\n")

      try do
        TestSupport.with_env(%{"AMP_CLI_PATH" => js_path, "PATH" => dir}, fn ->
          assert {:ok, %CommandSpec{program: ^node_path, argv_prefix: [^js_path]}} =
                   ProviderCLI.resolve(:amp)
        end)
      after
        File.rm_rf(dir)
      end
    end

    test "Amp finds the default home binary locations" do
      home = TestSupport.tmp_dir!("core_amp_cli_home")
      bin_dir = Path.join([home, ".amp", "bin"])
      File.mkdir_p!(bin_dir)
      amp_path = TestSupport.write_executable!(bin_dir, "amp", "#!/bin/bash\nexit 0\n")

      try do
        TestSupport.with_env(%{"HOME" => home, "PATH" => "/nonexistent_dir_only"}, fn ->
          assert {:ok, %CommandSpec{program: ^amp_path, argv_prefix: []}} =
                   ProviderCLI.resolve(:amp)
        end)
      after
        File.rm_rf(home)
      end
    end

    test "Claude honors CLAUDE_CLI_PATH" do
      dir = TestSupport.tmp_dir!("core_claude_cli")
      claude_path = TestSupport.write_executable!(dir, "claude", "#!/bin/bash\nexit 0\n")

      try do
        TestSupport.with_env(%{"CLAUDE_CLI_PATH" => claude_path}, fn ->
          assert {:ok, %CommandSpec{program: ^claude_path, argv_prefix: []}} =
                   ProviderCLI.resolve(:claude)
        end)
      after
        File.rm_rf(dir)
      end
    end

    test "Claude prefers claude-code on PATH" do
      dir = TestSupport.tmp_dir!("core_claude_cli_path")

      claude_code_path =
        TestSupport.write_executable!(dir, "claude-code", "#!/bin/bash\nexit 0\n")

      try do
        TestSupport.with_env(%{"CLAUDE_CLI_PATH" => nil, "PATH" => dir}, fn ->
          assert {:ok, %CommandSpec{program: ^claude_code_path, argv_prefix: []}} =
                   ProviderCLI.resolve(:claude)
        end)
      after
        File.rm_rf(dir)
      end
    end

    test "Claude falls back to known locations when PATH is empty" do
      dir = TestSupport.tmp_dir!("core_claude_cli_home")
      bin_dir = Path.join([dir, ".local", "bin"])
      File.mkdir_p!(bin_dir)
      claude_path = TestSupport.write_executable!(bin_dir, "claude", "#!/bin/bash\nexit 0\n")

      try do
        TestSupport.with_env(%{"CLAUDE_CLI_PATH" => nil, "PATH" => "/nonexistent_dir_only"}, fn ->
          assert {:ok, %CommandSpec{program: ^claude_path, argv_prefix: []}} =
                   ProviderCLI.resolve(:claude, [], known_locations: [claude_path])
        end)
      after
        File.rm_rf(dir)
      end
    end
  end

  test "explicit command overrides are preserved without filesystem discovery" do
    assert {:ok, %CommandSpec{program: "custom-gemini", argv_prefix: []}} =
             ProviderCLI.resolve(:gemini, command: "custom-gemini")
  end

  test "remote execution surfaces bypass local CODEX_PATH leakage and fall back to the provider command name" do
    dir = TestSupport.tmp_dir!("core_codex_remote_resolution")
    codex_path = TestSupport.write_executable!(dir, "codex", "#!/bin/bash\nexit 0\n")

    try do
      TestSupport.with_env(%{"CODEX_PATH" => codex_path}, fn ->
        assert {:ok, %CommandSpec{program: "codex", argv_prefix: []}} =
                 ProviderCLI.resolve(
                   :codex,
                   [],
                   execution_surface: [
                     surface_kind: :ssh_exec,
                     transport_options: [destination: "ssh.example"]
                   ]
                 )
      end)
    after
      File.rm_rf(dir)
    end
  end

  test "remote execution surfaces preserve explicit remote path overrides without local validation" do
    assert {:ok, %CommandSpec{program: "/remote/bin/codex", argv_prefix: []}} =
             ProviderCLI.resolve(
               :codex,
               [command: "/remote/bin/codex"],
               execution_surface: [
                 surface_kind: :ssh_exec,
                 transport_options: [destination: "ssh.example"]
               ]
             )
  end

  test "remote execution surfaces use the provider's remote default command when it differs from local discovery order" do
    assert {:ok, %CommandSpec{program: "claude", argv_prefix: []}} =
             ProviderCLI.resolve(
               :claude,
               [],
               execution_surface: [
                 surface_kind: :ssh_exec,
                 transport_options: [destination: "ssh.example"]
               ]
             )
  end

  test "guest path semantics bypass local resolution even when the surface is not remote" do
    dir = TestSupport.tmp_dir!("core_codex_guest_path_resolution")
    codex_path = TestSupport.write_executable!(dir, "codex", "#!/bin/bash\nexit 0\n")

    try do
      TestSupport.with_env(%{"CODEX_PATH" => codex_path}, fn ->
        assert {:ok, %CommandSpec{program: "codex", argv_prefix: []}} =
                 ProviderCLI.resolve(
                   :codex,
                   [],
                   execution_surface: [surface_kind: :guest_bridge]
                 )
      end)
    after
      File.rm_rf(dir)
    end
  end

  test "guest path semantics preserve explicit guest command overrides without local validation" do
    assert {:ok, %CommandSpec{program: "/guest/bin/codex", argv_prefix: []}} =
             ProviderCLI.resolve(
               :codex,
               [command: "/guest/bin/codex"],
               execution_surface: [surface_kind: :guest_bridge]
             )
  end

  describe "runtime_failure/3" do
    test "classifies remote command-not-found exits as cli_not_found" do
      exit =
        ProcessExit.from_reason({:exit_status, 127},
          stderr: "bash: line 1: exec: claude-code: not found\n"
        )

      assert %ErrorRuntimeFailure{} =
               failure =
               ProviderCLI.runtime_failure(
                 :claude,
                 exit,
                 execution_surface: [
                   surface_kind: :ssh_exec,
                   transport_options: [destination: "ssh.example"]
                 ]
               )

      assert failure.kind == :cli_not_found
      assert failure.exit_code == 127
      assert failure.message =~ "Claude CLI not found"
      assert failure.message =~ "remote target ssh.example"
      assert failure.message =~ "remote non-login PATH"
      assert ProviderCLI.runtime_failure_code(failure) == "cli_not_found"
    end

    test "classifies env-wrapper remote command misses as cli_not_found" do
      exit =
        ProcessExit.from_reason({:exit_status, 127},
          stderr: "env: ‘gemini’: No such file or directory\n"
        )

      assert %ErrorRuntimeFailure{} =
               failure =
               ProviderCLI.runtime_failure(
                 :gemini,
                 exit,
                 execution_surface: [
                   surface_kind: :ssh_exec,
                   transport_options: [destination: "gemini.example"]
                 ]
               )

      assert failure.kind == :cli_not_found
      assert failure.exit_code == 127
      assert failure.message =~ "Gemini CLI not found"
      assert failure.message =~ "remote target gemini.example"
      assert failure.message =~ "remote non-login PATH"
    end

    test "classifies remote cwd misses as config_invalid runtime failures" do
      exit =
        ProcessExit.from_reason({:exit_status, 1},
          stderr: "bash: line 1: cd: /remote/worktree: No such file or directory\n"
        )

      assert %ErrorRuntimeFailure{} =
               failure =
               ProviderCLI.runtime_failure(
                 :amp,
                 exit,
                 cwd: "/remote/worktree",
                 execution_surface: [
                   surface_kind: :ssh_exec,
                   transport_options: [destination: "amp.example"]
                 ]
               )

      assert failure.kind == :cwd_not_found
      assert failure.message =~ "/remote/worktree"
      assert failure.message =~ "remote target amp.example"
      assert ProviderCLI.runtime_failure_code(failure) == "config_invalid"
    end

    test "classifies guest-path command misses without pretending they are remote targets" do
      exit =
        ProcessExit.from_reason({:exit_status, 127},
          stderr: "env: codex: No such file or directory\n"
        )

      assert %ErrorRuntimeFailure{} =
               failure =
               ProviderCLI.runtime_failure(
                 :codex,
                 exit,
                 execution_surface: [surface_kind: :guest_bridge]
               )

      assert failure.kind == :cli_not_found
      assert failure.message =~ "Codex CLI not found on the attached guest surface"
      assert failure.message =~ "guest PATH env override"
      refute failure.message =~ "remote target"
    end
  end

  defp build_fake_asdf_codex do
    root = TestSupport.tmp_dir!("core_codex_asdf")
    asdf_root = Path.join(root, ".asdf")
    bin_dir = Path.join(asdf_root, "bin")
    shim_dir = Path.join(asdf_root, "shims")
    installs_dir = Path.join(root, "installs/nodejs/25.1.0/bin")

    File.mkdir_p!(bin_dir)
    File.mkdir_p!(shim_dir)
    File.mkdir_p!(installs_dir)

    resolved_path =
      TestSupport.write_executable!(
        installs_dir,
        "codex",
        "#!/bin/bash\nprintf 'codex-cli 0.0.0\\n'\n"
      )

    asdf_path =
      TestSupport.write_executable!(
        bin_dir,
        "asdf",
        """
        #!/bin/sh
        if [ "$1" = "which" ] && [ "$2" = "codex" ]; then
          printf '%s\\n' "#{resolved_path}"
          exit 0
        fi

        printf 'unsupported asdf invocation: %s %s\\n' "$1" "$2" >&2
        exit 1
        """
      )

    shim_path =
      TestSupport.write_executable!(
        shim_dir,
        "codex",
        """
        #!/bin/sh
        exec "#{asdf_path}" exec "codex" "$@"
        """
      )

    {root, shim_path, resolved_path}
  end

  defp build_fake_asdf_codex_js do
    root = TestSupport.tmp_dir!("core_codex_asdf_js")
    asdf_root = Path.join(root, ".asdf")
    bin_dir = Path.join(asdf_root, "bin")
    shim_dir = Path.join(asdf_root, "shims")
    node_bin_dir = Path.join(root, "installs/nodejs/25.1.0/bin")
    codex_bin_dir = Path.join(root, "installs/nodejs/25.1.0/lib/node_modules/@openai/codex/bin")

    File.mkdir_p!(bin_dir)
    File.mkdir_p!(shim_dir)
    File.mkdir_p!(node_bin_dir)
    File.mkdir_p!(codex_bin_dir)

    node_path =
      TestSupport.write_executable!(
        node_bin_dir,
        "node",
        "#!/bin/sh\nprintf 'node 25.1.0\\n'\n"
      )

    script_path =
      TestSupport.write_executable!(
        codex_bin_dir,
        "codex.js",
        "#!/usr/bin/env node\nconsole.log('codex');\n"
      )

    asdf_path =
      TestSupport.write_executable!(
        bin_dir,
        "asdf",
        """
        #!/bin/sh
        if [ "$1" = "which" ] && [ "$2" = "codex" ]; then
          printf '%s\\n' "#{script_path}"
          exit 0
        fi

        if [ "$1" = "which" ] && [ "$2" = "node" ]; then
          printf '%s\\n' "#{node_path}"
          exit 0
        fi

        printf 'unsupported asdf invocation: %s %s\\n' "$1" "$2" >&2
        exit 1
        """
      )

    codex_shim_path =
      TestSupport.write_executable!(
        shim_dir,
        "codex",
        """
        #!/bin/sh
        exec "#{asdf_path}" exec "codex" "$@"
        """
      )

    TestSupport.write_executable!(
      shim_dir,
      "node",
      """
      #!/bin/sh
      exec "#{asdf_path}" exec "node" "$@"
      """
    )

    {root, codex_shim_path, script_path, node_path}
  end

  defp build_fake_codex_with_non_shim_node_marker do
    root = TestSupport.tmp_dir!("core_codex_non_shim_marker")
    bin_dir = Path.join(root, ".asdf/installs/nodejs/25.1.0/bin")

    File.mkdir_p!(bin_dir)

    node_path =
      TestSupport.write_executable!(
        bin_dir,
        "node",
        """
        #!/bin/sh
        # accidental marker from unrelated contents: mise exec
        exit 0
        """
      )

    script_path =
      TestSupport.write_executable!(
        bin_dir,
        "codex",
        "#!/usr/bin/env node\nconsole.log('codex');\n"
      )

    {root, script_path, node_path}
  end
end
