defmodule CliSubprocessCore.LiveSSHTest do
  use ExUnit.Case, async: false

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.TestSupport.LiveSSH
  alias ExternalRuntimeTransport.Transport.RunResult

  @moduletag :live_ssh
  @moduletag timeout: 60_000

  @live_ssh_enabled LiveSSH.enabled?()

  if not @live_ssh_enabled do
    @moduletag skip: LiveSSH.skip_reason()
  end

  test "raw SSH execution surface runs a simple remote shell command" do
    assert {:ok, %RunResult{} = result} =
             LiveSSH.run("printf", ["CLI_SUBPROCESS_CORE_LIVE_SSH_OK"])

    assert result.exit.status == :success
    assert result.stdout == "CLI_SUBPROCESS_CORE_LIVE_SSH_OK"
  end

  test "provider-aware Codex execution uses a canonical remote execution_surface" do
    if LiveSSH.runnable?("codex") do
      assert {:ok, %RunResult{} = result} =
               Command.run(
                 provider: :codex,
                 prompt: "Reply with exactly: CLI_SUBPROCESS_CORE_REMOTE_CODEX_OK",
                 permission_mode: :bypass,
                 skip_git_repo_check: true,
                 execution_surface: LiveSSH.execution_surface(),
                 timeout: 120_000,
                 stderr: :separate
               )

      assert result.exit.status == :success
      assert result.output =~ "CLI_SUBPROCESS_CORE_REMOTE_CODEX_OK"
    else
      assert true
    end
  end
end
