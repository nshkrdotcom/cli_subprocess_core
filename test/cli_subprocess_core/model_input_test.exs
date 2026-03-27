defmodule CliSubprocessCore.ModelInputTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ModelInput
  alias CliSubprocessCore.ModelRegistry.Selection

  test "normalizes raw Codex Ollama attrs into one payload and strips raw keys" do
    assert {:ok, normalized} =
             ModelInput.normalize(:codex,
               model: "llama3.2",
               provider_backend: :oss,
               oss_provider: "ollama",
               ollama_base_url: "http://127.0.0.1:22434",
               ollama_http: &ollama_http/4
             )

    assert %Selection{} = normalized.selection
    assert normalized.selection.provider == :codex
    assert normalized.selection.resolved_model == "llama3.2"

    assert normalized.selection.env_overrides == %{
             "CODEX_OSS_BASE_URL" => "http://127.0.0.1:22434/v1"
           }

    assert normalized.attrs[:model_payload] == normalized.selection
    refute Keyword.has_key?(normalized.attrs, :model)
    refute Keyword.has_key?(normalized.attrs, :provider_backend)
    refute Keyword.has_key?(normalized.attrs, :oss_provider)
    refute Keyword.has_key?(normalized.attrs, :ollama_base_url)
    refute Keyword.has_key?(normalized.attrs, :ollama_http)
  end

  test "validates conflicts between raw attrs and a supplied payload" do
    payload =
      Selection.new(%{
        provider: :codex,
        requested_model: "llama3.2",
        resolved_model: "llama3.2",
        resolution_source: :explicit,
        reasoning: "high",
        reasoning_effort: nil,
        normalized_reasoning_effort: nil,
        model_family: "llama",
        catalog_version: nil,
        visibility: :public,
        provider_backend: :oss,
        model_source: :external,
        env_overrides: %{"CODEX_OSS_BASE_URL" => "http://127.0.0.1:22434/v1"},
        settings_patch: %{},
        backend_metadata: %{
          "provider_backend" => "oss",
          "oss_provider" => "ollama",
          "external_model" => "llama3.2"
        },
        errors: []
      })

    assert {:error, {:model_payload_conflict, :model, "llama3.2", "gpt-5.4"}} =
             ModelInput.normalize(:codex,
               model_payload: payload,
               model: "gpt-5.4"
             )

    assert {:error,
            {:model_payload_conflict, :ollama_base_url, "http://127.0.0.1:22434/v1",
             "http://127.0.0.1:11434/v1"}} =
             ModelInput.normalize(:codex,
               model_payload: payload,
               ollama_base_url: "http://127.0.0.1:11434"
             )
  end

  test "treats raw Codex Ollama roots and /v1 payload overrides as equivalent" do
    payload =
      Selection.new(%{
        provider: :codex,
        requested_model: "llama3.2",
        resolved_model: "llama3.2",
        resolution_source: :explicit,
        reasoning: "high",
        reasoning_effort: nil,
        normalized_reasoning_effort: nil,
        model_family: "llama",
        catalog_version: nil,
        visibility: :public,
        provider_backend: :oss,
        model_source: :external,
        env_overrides: %{"CODEX_OSS_BASE_URL" => "http://127.0.0.1:22434/v1"},
        settings_patch: %{},
        backend_metadata: %{
          "provider_backend" => "oss",
          "oss_provider" => "ollama",
          "external_model" => "llama3.2"
        },
        errors: []
      })

    assert {:ok, normalized} =
             ModelInput.normalize(:codex,
               model_payload: payload,
               ollama_base_url: "http://127.0.0.1:22434"
             )

    assert normalized.selection == payload
  end

  test "validates Claude payload conflicts through the shared normalizer" do
    {:ok, payload} = CliSubprocessCore.ModelRegistry.build_arg_payload(:claude, "sonnet", [])

    assert {:error, {:model_payload_conflict, :model, "sonnet", "opus"}} =
             ModelInput.normalize(:claude,
               model_payload: payload,
               model: "opus"
             )
  end

  test "validates Gemini payload conflicts through the shared normalizer" do
    {:ok, payload} =
      CliSubprocessCore.ModelRegistry.build_arg_payload(:gemini, "gemini-2.5-flash", [])

    assert {:error, {:model_payload_conflict, :model, "gemini-2.5-flash", "gemini-2.5-pro"}} =
             ModelInput.normalize(:gemini,
               model_payload: payload,
               model: "gemini-2.5-pro"
             )
  end

  defp ollama_http(:get, "/api/version", nil, _opts) do
    {:ok, 200, %{"version" => "0.18.2"}}
  end

  defp ollama_http(:get, "/api/tags", nil, _opts) do
    {:ok, 200, %{"models" => [%{"name" => "llama3.2:latest", "model" => "llama3.2:latest"}]}}
  end

  defp ollama_http(:get, "/api/ps", nil, _opts) do
    {:ok, 200, %{"models" => [%{"name" => "llama3.2:latest", "model" => "llama3.2:latest"}]}}
  end

  defp ollama_http(:post, "/api/show", %{"model" => "llama3.2"}, _opts) do
    {:ok, 200,
     %{
       "capabilities" => ["completion", "tools"],
       "details" => %{
         "family" => "llama",
         "parameter_size" => "3.2B",
         "quantization_level" => "Q4_0"
       },
       "model_info" => %{"llama.context_length" => 8192},
       "modified_at" => "2026-03-25T00:00:00Z"
     }}
  end

  defp ollama_http(_method, _path, _body, _opts), do: {:ok, 200, %{}}
end
