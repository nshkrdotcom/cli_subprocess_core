defmodule CliSubprocessCore.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ModelCatalog

  describe "ModelCatalog.load/1" do
    test "loads known provider catalogs" do
      assert {:ok, codex_catalog} = ModelCatalog.load(:codex)
      assert codex_catalog.provider == :codex
      assert codex_catalog.catalog_version == "2026-07-10"
      assert codex_catalog.remote_default == "gpt-5.6-sol"

      assert Enum.map(codex_catalog.models, & &1.id) == [
               "gpt-5.6-sol",
               "gpt-5.6-terra",
               "gpt-5.6-luna",
               "gpt-5.5",
               "gpt-5.4",
               "gpt-5.4-mini",
               "gpt-5.3-codex-spark",
               "codex-auto-review"
             ]

      refute Enum.any?(codex_catalog.models, &(&1.id == "gpt-5.2-codex"))
      refute Enum.any?(codex_catalog.models, &(&1.id == "gpt-5.1-codex-max"))
      refute Enum.any?(codex_catalog.models, &(&1.id == "gpt-5-codex"))
      refute Enum.any?(codex_catalog.models, &(&1.id == "gpt-5-codex-internal"))
      # Confirmed absent via a live `model/list` probe (includeHidden: true)
      # against an authenticated codex CLI v0.144.1 install, 2026-07-10.
      refute Enum.any?(codex_catalog.models, &(&1.id == "gpt-5.3-codex"))
      refute Enum.any?(codex_catalog.models, &(&1.id == "gpt-5.2"))

      assert Enum.find(codex_catalog.models, &(&1.id == "gpt-5.6-sol")).default

      refute Enum.find(codex_catalog.models, &(&1.id == "gpt-5.5")).default

      assert codex_catalog.models
             |> Enum.find(&(&1.id == "gpt-5.6-sol"))
             |> Map.fetch!(:reasoning_efforts)
             |> Map.keys()
             |> Enum.sort() == ["high", "low", "max", "medium", "ultra", "xhigh"]

      assert codex_catalog.models
             |> Enum.find(&(&1.id == "gpt-5.6-terra"))
             |> Map.fetch!(:reasoning_efforts)
             |> Map.keys()
             |> Enum.sort() == ["high", "low", "max", "medium", "ultra", "xhigh"]

      assert codex_catalog.models
             |> Enum.find(&(&1.id == "gpt-5.6-luna"))
             |> Map.fetch!(:reasoning_efforts)
             |> Map.keys()
             |> Enum.sort() == ["high", "low", "max", "medium", "xhigh"]

      for {model_id, default_effort} <- [
            {"gpt-5.6-sol", "low"},
            {"gpt-5.6-terra", "medium"},
            {"gpt-5.6-luna", "medium"}
          ] do
        model = Enum.find(codex_catalog.models, &(&1.id == model_id))
        assert model.default_reasoning_effort == default_effort
        assert model.aliases == []
      end

      spark = Enum.find(codex_catalog.models, &(&1.id == "gpt-5.3-codex-spark"))
      assert spark.visibility == :public
      assert spark.default_reasoning_effort == "high"
      assert spark.metadata["supported_in_api"] == false
      assert spark.metadata["input_modalities"] == ["text"]

      assert spark.reasoning_efforts |> Map.keys() |> Enum.sort() ==
               ["high", "low", "medium", "xhigh"]

      assert Enum.find(codex_catalog.models, &(&1.id == "codex-auto-review")).visibility ==
               :internal

      refute Enum.find(codex_catalog.models, &(&1.id == "gpt-5.4")).metadata["upgrade"]

      assert {:ok, claude_catalog} = ModelCatalog.load(:claude)
      assert claude_catalog.provider == :claude
      assert claude_catalog.catalog_version == "2026-07-25"
      assert claude_catalog.remote_default == "sonnet"

      assert Enum.map(claude_catalog.models, & &1.id) == [
               "sonnet",
               "sonnet[1m]",
               "opus",
               "opus[1m]",
               "fable",
               "haiku",
               "legacy-sonnet"
             ]

      assert Enum.any?(claude_catalog.models, fn model ->
               model.id == "opus" and "claude-opus-5" in model.aliases and
                 model.metadata["display_name"] == "Opus 5"
             end)

      # `opus[1m]` is retained only as a compatibility choice. Opus 5 is itself
      # a 1M-context model, so there is no separate suffixed provider id.
      assert Enum.any?(claude_catalog.models, fn model ->
               model.id == "opus[1m]" and "claude-opus-5" in model.aliases
             end)

      refute Enum.any?(claude_catalog.models, fn model ->
               "claude-opus-5[1m]" in model.aliases
             end)

      # Prior full ids stay resolvable, matching how the Sonnet entry retains
      # `claude-sonnet-4-6`.
      assert Enum.any?(claude_catalog.models, fn model ->
               model.id == "opus" and "claude-opus-4-8" in model.aliases
             end)

      assert Enum.any?(claude_catalog.models, fn model ->
               model.id == "sonnet" and "claude-sonnet-5" in model.aliases
             end)

      assert Enum.any?(claude_catalog.models, fn model ->
               model.id == "fable" and "claude-fable-5" in model.aliases
             end)

      assert Enum.find(claude_catalog.models, &(&1.id == "sonnet")).reasoning_efforts
             |> Map.keys()
             |> Enum.sort() == ["high", "low", "max", "medium", "xhigh"]

      assert Enum.find(claude_catalog.models, &(&1.id == "opus")).reasoning_efforts
             |> Map.keys()
             |> Enum.sort() == ["high", "low", "max", "medium", "xhigh"]

      assert Enum.find(claude_catalog.models, &(&1.id == "fable")).reasoning_efforts
             |> Map.keys()
             |> Enum.sort() == ["high", "low", "max", "medium", "xhigh"]

      assert Enum.find(claude_catalog.models, &(&1.id == "haiku")).reasoning_efforts == %{}

      refute Enum.any?(claude_catalog.models, fn model ->
               "claude-opus-4-6" in model.aliases
             end)

      assert {:ok, amp_catalog} = ModelCatalog.load(:amp)
      assert amp_catalog.provider == :amp
      assert Enum.any?(amp_catalog.models, &(&1.id == "amp-1"))

      assert {:ok, cursor_catalog} = ModelCatalog.load(:cursor)
      assert cursor_catalog.provider == :cursor
      assert cursor_catalog.catalog_version == "2026-05-28"
      assert cursor_catalog.remote_default == "composer-2.5-fast"

      assert Enum.map(cursor_catalog.models, & &1.id) == [
               "composer-2.5-fast",
               "composer-2.5",
               "gpt-5.3-codex",
               "gpt-5.2",
               "claude-4-sonnet",
               "claude-4-sonnet-thinking",
               "gemini-3-flash"
             ]

      assert {:ok, antigravity_catalog} = ModelCatalog.load(:antigravity)
      assert antigravity_catalog.provider == :antigravity
      assert antigravity_catalog.catalog_version == "2026-05-28"
      assert antigravity_catalog.remote_default == "default"
      assert Enum.map(antigravity_catalog.models, & &1.id) == ["default"]
    end

    test "returns model_unavailable for missing provider catalog" do
      assert {:error, {:model_unavailable, :missing_provider, _}} =
               ModelCatalog.load(:missing_provider)
    end

    test "loads the embedded catalog when an archive path is not a directory" do
      temp_root =
        Path.join(
          System.tmp_dir!(),
          "cli-subprocess-catalog-#{System.unique_integer([:positive])}"
        )

      archive_path = Path.join(temp_root, "prompt_runner.escript")

      :ok = File.mkdir_p(temp_root)
      :ok = File.write(archive_path, "archive")

      on_exit(fn -> File.rm_rf(temp_root) end)

      assert {:ok, catalog} =
               archive_path
               |> Path.join("priv/models/codex.json")
               |> then(&ModelCatalog.load_from_path(:codex, &1))

      assert catalog.provider == :codex
      assert catalog.remote_default == "gpt-5.6-sol"
    end
  end
end
