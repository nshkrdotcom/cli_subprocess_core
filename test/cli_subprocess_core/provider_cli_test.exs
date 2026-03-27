defmodule CliSubprocessCore.ProviderCLITest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.CommandSpec
  alias CliSubprocessCore.ProviderCLI
  alias CliSubprocessCore.ProviderCLI.Error
  alias CliSubprocessCore.TestSupport

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
  end

  test "explicit command overrides are preserved without filesystem discovery" do
    assert {:ok, %CommandSpec{program: "custom-gemini", argv_prefix: []}} =
             ProviderCLI.resolve(:gemini, command: "custom-gemini")
  end
end
