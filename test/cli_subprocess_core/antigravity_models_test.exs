defmodule CliSubprocessCore.AntigravityModelsTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.{AntigravityModels, ModelRegistry}
  alias CliSubprocessCore.ProviderProfiles.Antigravity

  @tag :tmp_dir
  test "discovery preserves account order and exact slugs", %{tmp_dir: dir} do
    path = Path.join(dir, "agy")
    fixture = Path.expand("../fixtures/antigravity_models_20261118.tsv", __DIR__)
    File.write!(path, "#!/bin/sh\ncat '#{fixture}'\n")
    File.chmod!(path, 0o700)

    assert {:ok, [%{id: "gemini-4-neon-high"} | _] = models} =
             AntigravityModels.list(cli_path: path)

    assert Enum.any?(models, &(&1.id == "gemini-pro-orchestrator-g1-pro"))
    refute Enum.any?(models, &String.contains?(&1.id, "carbon"))
  end

  test "discovery distinguishes empty output from process failure" do
    assert {:ok, []} = AntigravityModels.list(cli_path: "/usr/bin/true")
    assert {:error, :model_list_failed} = AntigravityModels.list(cli_path: "/usr/bin/false")
  end

  test "a Carbon slug can be selected offline and reaches agy unchanged" do
    assert {:ok, selection} = ModelRegistry.resolve(:antigravity, "gemini-4-carbon-high")

    assert {:ok, invocation} =
             Antigravity.build_invocation(prompt: "OK", model_payload: selection)

    assert Enum.chunk_every(invocation.args, 2)
           |> Enum.member?(["--model", "gemini-4-carbon-high"])
  end

  test "Neon slugs resolve exactly and Orchestrator leaves effort unset" do
    for level <- ~w(low medium high xhigh) do
      slug = "gemini-4-neon-#{level}"

      assert {:ok, %{resolved_model: ^slug, reasoning: nil}} =
               ModelRegistry.resolve(:antigravity, slug)
    end

    slug = "gemini-pro-orchestrator-neon"

    assert {:ok, %{resolved_model: ^slug, reasoning: nil}} =
             ModelRegistry.resolve(:antigravity, slug)

    assert {:error, {:invalid_reasoning_effort, "high", [], :antigravity}} =
             ModelRegistry.resolve(:antigravity, slug, reasoning: "high")
  end

  test "a rejected model is a fatal error with an account discovery hint" do
    state = Antigravity.init_parser_state([])

    line =
      ~s|{"event":"result","result":{"status":"ERROR","error":"invalid model selection (--model carbon): unavailable"}}|

    assert {[%{kind: :error, payload: payload}], _state} = Antigravity.decode_stdout(line, state)
    assert payload.code == "model_rejected"
    assert payload.severity == :fatal
    assert payload.message =~ "active account"
  end
end
