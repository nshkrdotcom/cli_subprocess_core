defmodule CliSubprocessCore.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.ModelCatalog

  describe "ModelCatalog.load/1" do
    test "loads known provider catalogs" do
      assert {:ok, codex_catalog} = ModelCatalog.load(:codex)
      assert codex_catalog.provider == :codex
      assert codex_catalog.catalog_version == "2026-09-07"
      assert codex_catalog.remote_default == "gpt-6-astra"

      fixture = File.read!(Path.expand("../fixtures/codex_model_list_20260907.json", __DIR__))
      live = Jason.decode!(fixture)["data"]

      assert Enum.map(codex_catalog.models, & &1.id) == Enum.map(live, & &1["id"])

      for {model, expected} <- Enum.zip(codex_catalog.models, live) do
        assert model.default == expected["isDefault"]
        assert model.default_reasoning_effort == expected["defaultReasoningEffort"]
        assert model.visibility == :internal == expected["hidden"]
        assert model.metadata["display_name"] == expected["displayName"]

        assert model.reasoning_efforts |> Map.keys() |> Enum.sort() ==
                 expected["supportedReasoningEfforts"]
                 |> Enum.map(& &1["reasoningEffort"])
                 |> Enum.sort()
      end

      assert {:ok, claude_catalog} = ModelCatalog.load(:claude)
      assert claude_catalog.provider == :claude
      assert claude_catalog.catalog_version == "2026-09-17"
      assert claude_catalog.remote_default == "sonnet"

      assert Enum.map(claude_catalog.models, & &1.id) == [
               "sonnet",
               "sonnet[1m]",
               "opus",
               "opus[1m]",
               "fable",
               "claude-fable-5-1",
               "claude-fable-5",
               "claude-mythos-5-1",
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
               model.id == "claude-fable-5-1" and "fable-5.1" in model.aliases and
                 model.metadata["display_name"] == "Claude Fable 5.1"
             end)

      assert Enum.any?(claude_catalog.models, fn model ->
               model.id == "claude-mythos-5-1" and "mythos-5.1" in model.aliases and
                 model.visibility == :restricted
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
      assert antigravity_catalog.catalog_version == "2026-09-03"
      assert antigravity_catalog.remote_default == "default"

      assert Enum.map(antigravity_catalog.models, & &1.id) == [
               "default",
               "gemini-3.8-flash",
               "gemini-3.7-flash",
               "gemini-3.6-flash",
               "gemini-3.1-pro"
             ]
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
      assert catalog.remote_default == "gpt-6-astra"
    end
  end
end
