defmodule CliSubprocessCore.ModelRegistryTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ModelRegistry
  alias CliSubprocessCore.ModelRegistry.Model
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

    test "resolves Claude Ollama backend models through the core payload" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.resolve(:claude, "haiku",
                 provider_backend: :ollama,
                 external_model_overrides: %{"haiku" => "llama3.2"},
                 anthropic_base_url: "http://127.0.0.1:11434",
                 ollama_http: &ollama_http/4
               )

      assert payload.requested_model == "haiku"
      assert payload.resolved_model == "llama3.2"
      assert payload.provider_backend == :ollama
      assert payload.model_source == :external
      assert payload.model_family == "llama"

      assert payload.env_overrides == %{
               "ANTHROPIC_AUTH_TOKEN" => "ollama",
               "ANTHROPIC_API_KEY" => "",
               "ANTHROPIC_BASE_URL" => "http://127.0.0.1:11434"
             }

      assert payload.backend_metadata["external_model"] == "llama3.2"
    end

    test "resolves compatible Codex Ollama models through the core payload" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.resolve(:codex, "gpt-oss:20b",
                 provider_backend: :oss,
                 oss_provider: "ollama",
                 ollama_http: &ollama_http/4
               )

      assert payload.requested_model == "gpt-oss:20b"
      assert payload.resolved_model == "gpt-oss:20b"
      assert payload.provider_backend == :oss
      assert payload.model_source == :external
      assert payload.reasoning == "high"
      assert payload.model_family == "gpt-oss"
      assert payload.backend_metadata["oss_provider"] == "ollama"
      assert payload.backend_metadata["external_model"] == "gpt-oss:20b"
      assert payload.backend_metadata["support_tier"] == "validated_default"
      assert payload.backend_metadata["loaded"] == true
    end

    test "resolves arbitrary Codex Ollama models when Ollama can show them" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.resolve(:codex, "llama3.2",
                 provider_backend: :oss,
                 oss_provider: "ollama",
                 ollama_base_url: "http://127.0.0.1:22434",
                 ollama_http: &ollama_http/4
               )

      assert payload.requested_model == "llama3.2"
      assert payload.resolved_model == "llama3.2"
      assert payload.provider_backend == :oss
      assert payload.model_source == :external
      assert payload.model_family == "llama"
      assert payload.env_overrides == %{"CODEX_OSS_BASE_URL" => "http://127.0.0.1:22434/v1"}
      assert payload.backend_metadata["oss_provider"] == "ollama"
      assert payload.backend_metadata["external_model"] == "llama3.2"
      assert payload.backend_metadata["support_tier"] == "runtime_validated_only"
    end

    test "preserves explicit Codex Ollama /v1 endpoints in payload env overrides" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.resolve(:codex, "llama3.2",
                 provider_backend: :oss,
                 oss_provider: "ollama",
                 ollama_base_url: "http://127.0.0.1:22434/v1",
                 ollama_http: &ollama_http/4
               )

      assert payload.env_overrides == %{"CODEX_OSS_BASE_URL" => "http://127.0.0.1:22434/v1"}
    end

    test "defaults Codex Ollama model selection to gpt-oss:20b" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.resolve(:codex, nil,
                 provider_backend: :oss,
                 oss_provider: "ollama",
                 ollama_http: &ollama_http/4
               )

      assert payload.resolution_source == :default
      assert payload.resolved_model == "gpt-oss:20b"
      assert payload.reasoning == "high"
    end

    test "carries Codex model_provider backend metadata in the resolved payload" do
      assert {:ok, %Selection{} = payload} =
               ModelRegistry.resolve(:codex, "gpt-5-codex",
                 provider_backend: :model_provider,
                 model_provider: "gateway"
               )

      assert payload.provider_backend == :model_provider
      assert payload.resolved_model == "gpt-5-codex"
      assert payload.backend_metadata["model_provider"] == "gateway"
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

    test "lists installed Ollama models for Claude Ollama backend" do
      assert {:ok, models} =
               ModelRegistry.list_visible(:claude,
                 provider_backend: :ollama,
                 ollama_http: &ollama_http/4
               )

      assert "llama3.2:latest" in models
      assert "qwen3.5" in models
    end

    test "lists installed Ollama models for Codex OSS backend" do
      assert {:ok, models} =
               ModelRegistry.list_visible(:codex,
                 provider_backend: :oss,
                 oss_provider: "ollama",
                 ollama_http: &ollama_http/4
               )

      assert "gpt-oss:20b" in models
      assert "llama3.2:latest" in models
    end
  end

  describe "ModelRegistry.default_model/2" do
    test "returns the default model id for provider defaults" do
      assert {:ok, "gpt-5-codex"} = ModelRegistry.default_model(:codex)
    end

    test "hard fails when Claude Ollama backend has no explicit external default" do
      assert {:error, {:model_unavailable, :claude, :no_external_model_default}} =
               ModelRegistry.default_model(:claude, provider_backend: :ollama)
    end

    test "returns the Codex Ollama default model" do
      assert {:ok, "gpt-oss:20b"} =
               ModelRegistry.default_model(:codex,
                 provider_backend: :oss,
                 oss_provider: "ollama"
               )
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

    test "validates direct Claude Ollama model ids through the backend-aware request map" do
      assert {:ok, model} =
               ModelRegistry.validate(:claude,
                 model: "llama3.2",
                 provider_backend: :ollama,
                 ollama_http: &ollama_http/4
               )

      assert model.id == "llama3.2"
      assert model.family == "llama"
      assert model.metadata["backend"] == "ollama"
    end

    test "validates compatible Codex Ollama model ids through the backend-aware request map" do
      assert {:ok, model} =
               ModelRegistry.validate(:codex,
                 model: "gpt-oss:20b",
                 provider_backend: :oss,
                 oss_provider: "ollama",
                 ollama_http: &ollama_http/4
               )

      assert model.id == "gpt-oss:20b"
      assert model.family == "gpt-oss"
      assert model.metadata["backend"] == "ollama"
      assert model.metadata["support_tier"] == "validated_default"
      assert model.metadata["loaded"] == true
    end

    test "validates arbitrary direct Codex Ollama model ids through the backend-aware request map" do
      assert {:ok, model} =
               ModelRegistry.validate(:codex,
                 model: "llama3.2",
                 provider_backend: :oss,
                 oss_provider: "ollama",
                 ollama_http: &ollama_http/4
               )

      assert model.id == "llama3.2"
      assert model.family == "llama"
      assert model.metadata["backend"] == "ollama"
      assert model.metadata["support_tier"] == "runtime_validated_only"
    end
  end

  describe "schema-backed model payloads" do
    test "normalizes model metadata and preserves unknown fields" do
      assert {:ok, model} =
               Model.new(:codex, %{
                 "id" => " gpt-5-codex ",
                 "aliases" => [" codex ", :codex, "codex"],
                 "visibility" => "public",
                 "reasoning_efforts" => %{"high" => 1.0},
                 "default_reasoning_effort" => "high",
                 "future_flag" => true
               })

      assert %Model{
               provider: :codex,
               id: "gpt-5-codex",
               aliases: ["codex"],
               visibility: :public,
               reasoning_efforts: %{"high" => 1.0},
               default_reasoning_effort: "high",
               extra: %{"future_flag" => true}
             } = model

      assert Model.to_map(model)["future_flag"] == true
    end

    test "preserves selection extras while keeping ergonomic fields" do
      selection =
        Selection.new(%{
          "provider" => :codex,
          "resolved_model" => "gpt-5-codex",
          "resolution_source" => "default",
          "provider_backend" => :model_provider,
          "forward_compat" => %{"v" => 1}
        })

      assert %Selection{
               provider: :codex,
               resolved_model: "gpt-5-codex",
               resolution_source: :default,
               provider_backend: :model_provider,
               extra: %{"forward_compat" => %{"v" => 1}}
             } = selection

      assert Selection.to_map(selection)["forward_compat"] == %{"v" => 1}
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

  defp ollama_http(:get, "/api/tags", nil, _opts) do
    {:ok, 200,
     %{
       "models" => [
         %{"name" => "llama3.2:latest", "model" => "llama3.2:latest"},
         %{"name" => "gpt-oss:20b", "model" => "gpt-oss:20b"},
         %{"name" => "qwen3.5", "model" => "qwen3.5"}
       ]
     }}
  end

  defp ollama_http(:get, "/api/version", nil, _opts) do
    {:ok, 200, %{"version" => "0.18.2"}}
  end

  defp ollama_http(:get, "/api/ps", nil, _opts) do
    {:ok, 200,
     %{
       "models" => [
         %{"name" => "gpt-oss:20b", "model" => "gpt-oss:20b"}
       ]
     }}
  end

  defp ollama_http(:post, "/api/show", %{"model" => "llama3.2"}, _opts) do
    {:ok, 200,
     %{
       "capabilities" => ["completion", "tools"],
       "details" => %{"family" => "llama", "parameter_size" => "3.2B"},
       "model_info" => %{"llama.context_length" => 8192},
       "modified_at" => "2026-03-25T00:00:00Z"
     }}
  end

  defp ollama_http(:post, "/api/show", %{"model" => "gpt-oss:20b"}, _opts) do
    {:ok, 200,
     %{
       "capabilities" => ["completion", "tools"],
       "details" => %{
         "family" => "gpt-oss",
         "parameter_size" => "20B",
         "quantization_level" => "Q4_K_M"
       },
       "model_info" => %{"gpt-oss.context_length" => 131_072},
       "modified_at" => "2026-03-25T00:00:00Z"
     }}
  end

  defp ollama_http(:post, "/api/show", %{"model" => "qwen3.5"}, _opts) do
    {:ok, 200,
     %{
       "capabilities" => ["completion"],
       "details" => %{"family" => "qwen", "parameter_size" => "7B"},
       "modified_at" => "2026-03-25T00:00:00Z"
     }}
  end

  defp ollama_http(:post, "/api/show", %{"model" => model}, _opts) do
    {:ok, 404, %{"error" => "model '#{model}' not found"}}
  end
end
