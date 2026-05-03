defmodule CliSubprocessCore.Command.OptionsTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.Command.Options
  alias CliSubprocessCore.ProviderProfiles.Codex
  alias CliSubprocessCore.TestSupport.ProviderProfiles.CommandRunner

  test "reserves canonical execution_surface input off the provider lane" do
    assert {:ok, %Options{} = options} =
             Options.new(
               profile: CommandRunner,
               command: "/bin/sh",
               args: ["-c", "printf ready"],
               execution_surface: [
                 surface_kind: :local_subprocess,
                 target_id: "target-1",
                 lease_ref: "lease-1",
                 surface_ref: "surface-1",
                 boundary_class: :local,
                 observability: %{suite: :phase_b},
                 transport_options: [connect_timeout_ms: 1_500]
               ]
             )

    assert options.provider_options == [command: "/bin/sh", args: ["-c", "printf ready"]]
    assert options.surface_kind == :local_subprocess
    assert options.target_id == "target-1"
    assert options.lease_ref == "lease-1"
    assert options.surface_ref == "surface-1"
    assert options.boundary_class == :local
    assert options.observability == %{suite: :phase_b}
    assert options.transport_options == [connect_timeout_ms: 1_500]
  end

  test "accepts execution-plane-only surface kinds" do
    assert {:ok, %Options{} = options} =
             Options.new(
               profile: CommandRunner,
               command: "/bin/sh",
               args: ["-c", "printf ready"],
               execution_surface: [surface_kind: :test_guest_local]
             )

    assert options.surface_kind == :test_guest_local
  end

  test "governed provider options reject caller launch smuggling" do
    authority = governed_authority()

    assert {:error, {:governed_launch_smuggling, :env}} =
             Options.new(
               profile: Codex,
               prompt: "review",
               governed_authority: authority,
               env: %{"CODEX_HOME" => "/ambient"}
             )

    assert {:error, {:governed_launch_smuggling, :command}} =
             Options.new(
               profile: Codex,
               prompt: "review",
               governed_authority: authority,
               command: "codex"
             )

    assert {:error, {:governed_launch_smuggling, :config_root}} =
             Options.new(
               profile: Codex,
               prompt: "review",
               governed_authority: authority,
               config_root: "/ambient/config"
             )
  end

  test "governed provider options reject model env and backend config smuggling" do
    authority = governed_authority()

    assert {:error, {:governed_launch_smuggling, :model_payload, :env_overrides}} =
             Options.new(
               profile: Codex,
               prompt: "review",
               governed_authority: authority,
               model_payload: %{
                 resolved_model: "gpt-5.3-codex",
                 env_overrides: %{"CODEX_OSS_BASE_URL" => "http://localhost:11434/v1"}
               }
             )

    assert {:error, {:governed_launch_smuggling, :model_payload, :backend_metadata}} =
             Options.new(
               profile: Codex,
               prompt: "review",
               governed_authority: authority,
               model_payload: %{
                 resolved_model: "gpt-oss:20b",
                 backend_metadata: %{"config_values" => [~s(model_provider="ollama")]}
               }
             )
  end

  test "governed provider options carry materialized authority to provider profiles" do
    authority = governed_authority()

    assert {:ok, %Options{} = options} =
             Options.new(
               profile: Codex,
               prompt: "review",
               governed_authority: authority,
               target_id: "target-1",
               lease_ref: "lease-1"
             )

    assert options.governed_authority.command == "/authority/bin/codex"

    assert Keyword.fetch!(Options.provider_profile_options(options), :governed_authority).command ==
             "/authority/bin/codex"

    assert Keyword.fetch!(Options.provider_profile_options(options), :execution_surface).target_id ==
             "target-1"
  end

  defp governed_authority do
    [
      authority_ref: "authority://cli/options",
      credential_lease_ref: "lease://codex/options",
      target_ref: "target://local/options",
      command: "/authority/bin/codex",
      cwd: "/workspace",
      env: %{"CODEX_HOME" => "/authority/codex-home"},
      clear_env?: true,
      config_root: "/authority/config",
      auth_root: "/authority/auth",
      base_url: "https://authority.example/v1"
    ]
  end
end
