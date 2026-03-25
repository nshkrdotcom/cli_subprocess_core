defmodule CliSubprocessCore.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ModelCatalog

  describe "ModelCatalog.load/1" do
    test "loads known provider catalogs" do
      assert {:ok, codex_catalog} = ModelCatalog.load(:codex)
      assert codex_catalog.provider == :codex
      assert codex_catalog.catalog_version == "2026-03-25"
      assert is_binary(codex_catalog.remote_default)
      assert Enum.any?(codex_catalog.models, &(&1.id == "gpt-5-codex"))

      assert {:ok, claude_catalog} = ModelCatalog.load(:claude)
      assert claude_catalog.provider == :claude
      assert Enum.any?(claude_catalog.models, &(&1.id == "sonnet"))

      assert {:ok, gemini_catalog} = ModelCatalog.load(:gemini)
      assert gemini_catalog.provider == :gemini
      assert Enum.any?(gemini_catalog.models, &(&1.id == "gemini-2.5-pro"))

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
