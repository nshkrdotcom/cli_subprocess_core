defmodule CliSubprocessCore.ModelRegistryTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ModelRegistry
  alias CliSubprocessCore.ModelRegistry.Selection

  describe "ModelRegistry.resolve/3" do
    test "resolves with explicit request precedence" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.resolve(:codex, "gpt-5.3-codex", model: "legacy")

      assert payload.resolution_source == :explicit
      assert payload.resolved_model == "gpt-5.3-codex"
      assert payload.provider == :codex
    end

    test "ignores legacy model values passed through opts" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.resolve(:codex, nil, model: "gpt-5.3-codex")

      assert payload.resolution_source == :default
      assert payload.resolved_model == "gpt-5-codex"
      assert payload.requested_model == nil
    end

    test "falls back to env model when explicit request is absent" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.resolve(:claude, nil, env_model: "legacy-sonnet")

      assert payload.resolution_source == :env
      assert payload.resolved_model == "legacy-sonnet"
    end

    test "falls back to provider default when no request or env model" do
      assert {:ok, %Selection{} = payload} = ModelRegistry.resolve(:gemini, nil)
      assert payload.resolution_source == :default
      assert payload.resolved_model == "gemini-2.5-pro"
    end

    test "errors on empty or placeholder model input" do
      assert {:error, {:empty_or_invalid_model, _, :codex}} = ModelRegistry.resolve(:codex, "")

      assert {:error, {:empty_or_invalid_model, _, :codex}} =
               ModelRegistry.resolve(:codex, "null")

      assert {:error, {:empty_or_invalid_model, _, :claude}} =
               ModelRegistry.resolve(:claude, nil, env_model: "nil")
    end

    test "errors with suggestions for unknown model" do
      assert {:error, {:unknown_model, "unknown", suggestions, :codex}} =
               ModelRegistry.resolve(:codex, "unknown")

      assert is_list(suggestions)
    end

    test "normalizes reasoning effort from resolved model" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.resolve(:codex, "gpt-5-codex", reasoning_effort: :high)

      assert payload.reasoning == "high"
      assert is_number(payload.reasoning_effort)
      assert payload.normalized_reasoning_effort == payload.reasoning_effort
    end

    test "errors on invalid reasoning effort" do
      assert {:error, {:invalid_reasoning_effort, :unsupported, _, :amp}} =
               ModelRegistry.resolve(:amp, "amp-1", reasoning_effort: :unsupported)
    end

    test "rejects unsupported low reasoning for gpt-5.4-mini" do
      assert {:error, {:invalid_reasoning_effort, :low, ["high", "medium"], :codex}} =
               ModelRegistry.resolve(:codex, "gpt-5.4-mini", reasoning_effort: :low)
    end
  end

  describe "ModelRegistry.list_visible/2" do
    test "returns visible models by default" do
      assert {:ok, models} = ModelRegistry.list_visible(:codex)
      assert "gpt-5-codex" in models
      refute "gpt-5-codex-internal" in models
    end

    test "returns all requested visibility families" do
      assert {:ok, models} = ModelRegistry.list_visible(:claude, visibility: :all)
      assert "sonnet" in models
      assert "legacy-sonnet" in models
    end
  end

  describe "ModelRegistry.default_model/2" do
    test "returns the default model id for provider defaults" do
      assert {:ok, "gpt-5-codex"} = ModelRegistry.default_model(:codex)
    end
  end

  describe "ModelRegistry.validate/2" do
    test "returns model metadata for a known model" do
      assert {:ok, model} = ModelRegistry.validate(:gemini, "gemini-2.5-pro")
      assert model.id == "gemini-2.5-pro"
    end

    test "returns hard error for invalid or unknown model" do
      assert {:error, {:unknown_model, "missing", _, :amp}} =
               ModelRegistry.validate(:amp, "missing")

      assert {:error, {:empty_or_invalid_model, _, :amp}} = ModelRegistry.validate(:amp, "nil")
    end
  end

  describe "ModelRegistry.normalize_reasoning_effort/3" do
    test "normalizes symbolic reasoning effort" do
      assert {:ok,
              %{reasoning: "medium", reasoning_effort: 1.0, normalized_reasoning_effort: 1.0}} =
               ModelRegistry.normalize_reasoning_effort(:codex, "gpt-5-codex", :medium)
    end

    test "normalizes numeric reasoning effort when configured" do
      assert {:ok, %{reasoning: "low", reasoning_effort: 0.8, normalized_reasoning_effort: 0.8}} =
               ModelRegistry.normalize_reasoning_effort(:codex, "gpt-5-codex", 0.8)
    end
  end

  describe "ModelRegistry.build_arg_payload/3" do
    test "builds the authoritative payload map" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.build_arg_payload(:amp, "amp-1", [])

      assert payload.resolved_model == "amp-1"
      assert payload.provider == :amp
      assert payload.visibility == :public
    end

    test "uses the model default reasoning when reasoning is omitted" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.build_arg_payload(:codex, "gpt-5.4-mini", [])

      assert payload.resolved_model == "gpt-5.4-mini"
      assert payload.reasoning == "medium"
    end
  end
end
