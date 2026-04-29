defmodule CliSubprocessCore.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ModelCatalog

  describe "ModelCatalog.load/1" do
    test "loads known provider catalogs" do
      assert {:ok, codex_catalog} = ModelCatalog.load(:codex)
      assert codex_catalog.provider == :codex
      assert codex_catalog.catalog_version == "2026-04-23"
      assert codex_catalog.remote_default == "gpt-5.4"

      assert Enum.map(codex_catalog.models, & &1.id) == [
               "gpt-5.4",
               "gpt-5.5",
               "gpt-5.4-mini",
               "gpt-5.3-codex",
               "gpt-5.3-codex-spark",
               "gpt-5.2"
             ]

      refute Enum.any?(codex_catalog.models, &(&1.id == "gpt-5.2-codex"))
      refute Enum.any?(codex_catalog.models, &(&1.id == "gpt-5.1-codex-max"))
      refute Enum.any?(codex_catalog.models, &(&1.id == "gpt-5-codex"))
      refute Enum.any?(codex_catalog.models, &(&1.id == "gpt-5-codex-internal"))

      assert {:ok, claude_catalog} = ModelCatalog.load(:claude)
      assert claude_catalog.provider == :claude
      assert claude_catalog.catalog_version == "2026-04-23"
      assert claude_catalog.remote_default == "sonnet"

      assert Enum.map(claude_catalog.models, & &1.id) == [
               "sonnet",
               "sonnet[1m]",
               "opus",
               "opus[1m]",
               "haiku",
               "legacy-sonnet"
             ]

      assert Enum.any?(claude_catalog.models, fn model ->
               model.id == "opus" and "claude-opus-4-7" in model.aliases
             end)

      assert Enum.find(claude_catalog.models, &(&1.id == "sonnet")).reasoning_efforts
             |> Map.keys()
             |> Enum.sort() == ["high", "low", "max", "medium"]

      assert Enum.find(claude_catalog.models, &(&1.id == "opus")).reasoning_efforts
             |> Map.keys()
             |> Enum.sort() == ["high", "low", "max", "medium", "xhigh"]

      assert Enum.find(claude_catalog.models, &(&1.id == "haiku")).reasoning_efforts == %{}

      refute Enum.any?(claude_catalog.models, fn model ->
               "claude-opus-4-6" in model.aliases
             end)

      assert {:ok, gemini_catalog} = ModelCatalog.load(:gemini)
      assert gemini_catalog.provider == :gemini
      assert gemini_catalog.catalog_version == "2026-04-28"
      assert gemini_catalog.remote_default == "auto-gemini-3"

      assert Enum.map(gemini_catalog.models, & &1.id) == [
               "auto-gemini-3",
               "auto-gemini-2.5",
               "pro",
               "flash",
               "flash-lite",
               "gemini-3.1-pro-preview",
               "gemini-3-flash-preview",
               "gemini-3.1-flash-lite-preview",
               "gemini-2.5-pro",
               "gemini-2.5-flash",
               "gemini-2.5-flash-lite"
             ]

      assert Enum.find(gemini_catalog.models, &(&1.id == "auto-gemini-3")).metadata[
               "cli_virtual_model"
             ] == true

      assert {:ok, amp_catalog} = ModelCatalog.load(:amp)
      assert amp_catalog.provider == :amp
      assert Enum.any?(amp_catalog.models, &(&1.id == "amp-1"))
    end

    test "returns model_unavailable for missing provider catalog" do
      assert {:error, {:model_unavailable, :missing_provider, _}} =
               ModelCatalog.load(:missing_provider)
    end
  end
end
