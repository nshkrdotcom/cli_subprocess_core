defmodule CliSubprocessCore.ProviderFeaturesTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ProviderFeatures

  alias CliSubprocessCore.ProviderProfiles.{
    Amp,
    Antigravity,
    Claude,
    Codex,
    Cursor,
    Gemini
  }

  test "permission manifests expose the provider-native bypass terms" do
    assert ProviderFeatures.permission_mode!(:gemini, :yolo).cli_excerpt == "--yolo"

    assert ProviderFeatures.permission_mode!(:claude, :bypass_permissions).cli_excerpt ==
             "--permission-mode bypassPermissions"

    assert ProviderFeatures.permission_mode!(:codex, :yolo).cli_excerpt ==
             "--dangerously-bypass-approvals-and-sandbox"

    assert ProviderFeatures.permission_mode!(:amp, :dangerously_allow_all).cli_excerpt ==
             "--dangerously-allow-all"

    assert ProviderFeatures.permission_mode!(:cursor, :bypass).cli_excerpt == "--force"
    assert ProviderFeatures.permission_mode!(:cursor, :plan).cli_excerpt == "--mode plan"

    assert ProviderFeatures.permission_mode!(:antigravity, :bypass).cli_excerpt ==
             "--dangerously-skip-permissions"
  end

  test "permission_args/2 returns the manifest-backed CLI arguments" do
    assert ProviderFeatures.permission_args(:gemini, :yolo) == ["--yolo"]

    assert ProviderFeatures.permission_args(:claude, :bypass_permissions) == [
             "--permission-mode",
             "bypassPermissions"
           ]

    assert ProviderFeatures.permission_args(:codex, :yolo) ==
             ["--dangerously-bypass-approvals-and-sandbox"]

    assert ProviderFeatures.permission_args(:amp, :dangerously_allow_all) ==
             ["--dangerously-allow-all"]

    assert ProviderFeatures.permission_args(:cursor, :bypass) == ["--force"]
    assert ProviderFeatures.permission_args(:cursor, :plan) == ["--mode", "plan"]
    assert ProviderFeatures.permission_args(:cursor, :ask) == []

    assert ProviderFeatures.permission_args(:antigravity, :bypass) == [
             "--dangerously-skip-permissions"
           ]
  end

  test "ollama partial feature support is explicit per provider" do
    claude = ProviderFeatures.partial_feature!(:claude, :ollama)
    codex = ProviderFeatures.partial_feature!(:codex, :ollama)
    gemini = ProviderFeatures.partial_feature!(:gemini, :ollama)
    amp = ProviderFeatures.partial_feature!(:amp, :ollama)
    cursor = ProviderFeatures.partial_feature!(:cursor, :ollama)
    antigravity = ProviderFeatures.partial_feature!(:antigravity, :ollama)

    assert claude.supported? == true
    assert claude.activation == %{provider_backend: :ollama}
    assert claude.model_strategy == :canonical_or_direct_external

    assert codex.supported? == true
    assert codex.activation == %{provider_backend: :oss, oss_provider: "ollama"}
    assert codex.model_strategy == :direct_external
    assert codex.compatibility.default_model == "gpt-oss:20b"
    assert codex.compatibility.acceptance == :runtime_validated_external_model
    assert codex.compatibility.validated_models == ["gpt-oss:20b"]

    assert gemini.supported? == false
    assert amp.supported? == false
    assert cursor.supported? == false
    assert antigravity.supported? == false
  end

  test "tool capability metadata separates observation from host execution" do
    for provider <- [:amp, :antigravity, :claude, :codex, :cursor, :gemini] do
      tool_capabilities = ProviderFeatures.tool_capabilities!(provider)

      assert Map.take(tool_capabilities, ProviderFeatures.tool_capability_keys()) ==
               %{
                 tool_events: true,
                 tool_results: true,
                 host_tools: false,
                 tool_allowlist: :unknown,
                 tool_denylist: :unknown,
                 mcp_servers: :unknown,
                 provider_builtin_tools: :unknown,
                 no_tool_mode: :unknown
               }

      assert is_list(tool_capabilities.notes)
      assert ProviderFeatures.tool_capability!(provider, :tool_events) == true
      assert ProviderFeatures.tool_capability!(provider, :tool_results) == true
      assert ProviderFeatures.tool_capability!(provider, :host_tools) == false
    end
  end

  test "coarse provider profile tools hints are not host tool admission" do
    profile_modules = [
      Amp,
      Claude,
      Codex,
      Cursor,
      Gemini
    ]

    for profile_module <- profile_modules do
      assert :tools in profile_module.capabilities()
      assert ProviderFeatures.tool_capability!(profile_module.id(), :host_tools) == false
    end

    refute :tools in Antigravity.capabilities()
    assert ProviderFeatures.tool_capability!(:antigravity, :host_tools) == false
  end
end
