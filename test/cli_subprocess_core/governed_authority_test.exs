defmodule CliSubprocessCore.GovernedAuthorityTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.{Command, GovernedAuthority}

  test "normalizes materialized launch authority without exposing raw values" do
    assert {:ok, authority} =
             GovernedAuthority.new(%{
               "authority_ref" => "authority://cli/1",
               "credential_lease_ref" => "lease://codex/1",
               "target_ref" => "target://local/1",
               "materialized_command" => "/authority/bin/codex",
               "materialized_cwd" => "/workspace",
               "materialized_env" => %{
                 :CODEX_HOME => "/authority/codex-home",
                 "OPENAI_API_KEY" => "fixture-value"
               },
               "clear_env?" => true,
               "config_root" => "/authority/config",
               "auth_root" => "/authority/auth",
               "base_url" => "https://authority.example/v1",
               "command_ref" => "command://codex/1",
               "redaction_ref" => "redaction://cli/1"
             })

    assert authority.command == "/authority/bin/codex"
    assert authority.cwd == "/workspace"

    assert authority.env == %{
             "CODEX_HOME" => "/authority/codex-home",
             "OPENAI_API_KEY" => "fixture-value"
           }

    assert authority.clear_env? == true

    assert GovernedAuthority.redacted(authority) == %{
             authority_ref: "authority://cli/1",
             credential_lease_ref: "lease://codex/1",
             target_ref: "target://local/1",
             command_ref: "command://codex/1",
             redaction_ref: "redaction://cli/1",
             command: "[redacted:20]",
             cwd: "[redacted:10]",
             env_keys: ["CODEX_HOME", "OPENAI_API_KEY"],
             clear_env?: true,
             config_root: "[redacted:17]",
             auth_root: "[redacted:15]",
             base_url: "[redacted:28]"
           }
  end

  test "requires clear env and authority refs" do
    assert {:error, {:missing_governed_authority_field, :authority_ref}} =
             GovernedAuthority.new(%{
               credential_lease_ref: "lease://codex/1",
               target_ref: "target://local/1",
               command: "/authority/bin/codex",
               clear_env?: true
             })

    assert {:error, {:invalid_governed_authority_field, :clear_env?, false}} =
             GovernedAuthority.new(%{
               authority_ref: "authority://cli/1",
               credential_lease_ref: "lease://codex/1",
               target_ref: "target://local/1",
               command: "/authority/bin/codex",
               clear_env?: false
             })
  end

  test "enforces prebuilt command launch against materialized authority" do
    authority = authority!()

    assert :ok =
             GovernedAuthority.enforce_invocation(
               Command.new("/authority/bin/codex", ["exec"],
                 cwd: "/workspace",
                 env: %{"CODEX_HOME" => "/authority/codex-home"},
                 clear_env?: true
               ),
               authority
             )

    assert {:error, {:governed_launch_mismatch, :command, "[redacted:5]"}} =
             GovernedAuthority.enforce_invocation(
               Command.new("codex", ["exec"],
                 cwd: "/workspace",
                 env: %{"CODEX_HOME" => "/authority/codex-home"},
                 clear_env?: true
               ),
               authority
             )

    assert {:error, {:governed_launch_mismatch, :clear_env?, false}} =
             GovernedAuthority.enforce_invocation(
               Command.new("/authority/bin/codex", ["exec"],
                 cwd: "/workspace",
                 env: %{"CODEX_HOME" => "/authority/codex-home"},
                 clear_env?: false
               ),
               authority
             )
  end

  defp authority! do
    GovernedAuthority.fetch!(
      authority_ref: "authority://cli/1",
      credential_lease_ref: "lease://codex/1",
      target_ref: "target://local/1",
      command: "/authority/bin/codex",
      cwd: "/workspace",
      env: %{"CODEX_HOME" => "/authority/codex-home"},
      clear_env?: true
    )
  end
end
