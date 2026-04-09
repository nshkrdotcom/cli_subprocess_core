defmodule CliSubprocessCore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/cli_subprocess_core"
  @homepage_url "https://hex.pm/packages/cli_subprocess_core"
  @docs_url "https://hexdocs.pm/cli_subprocess_core"

  def project do
    [
      app: :cli_subprocess_core,
      name: "CliSubprocessCore",
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      homepage_url: @homepage_url,
      source_url: @source_url,
      docs: docs(),
      package: package(),
      description: description(),
      dialyzer: dialyzer()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "overview",
      source_ref: "v#{@version}",
      homepage_url: @homepage_url,
      assets: %{"assets" => "assets"},
      logo: "assets/cli_subprocess_core.svg",
      extras: [
        "README.md": [title: "Overview", filename: "overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"],
        "guides/getting-started.md": [title: "Getting Started"],
        "guides/external-runtime-transport.md": [title: "External Runtime Transport"],
        "guides/execution-surface-compatibility.md": [title: "Execution Surface Compatibility"],
        "guides/event-and-payload-model.md": [title: "Event And Payload Model"],
        "guides/provider-profile-contract.md": [title: "Provider Profile Contract"],
        "guides/custom-provider-profiles.md": [title: "Custom Provider Profiles"],
        "guides/built-in-provider-profiles.md": [title: "Built-In Provider Profiles"],
        "guides/provider-feature-manifests.md": [title: "Provider Feature Manifests"],
        "guides/developer-guide-model-registry.md": [title: "Developer Guide: Model Registry"],
        "guides/developer-guide-runtime-layers.md": [title: "Developer Guide: Runtime Layers"],
        "guides/developer-guide-claude-backends.md": [title: "Developer Guide: Claude Backends"],
        "guides/developer-guide-codex-backends.md": [title: "Developer Guide: Codex Backends"],
        "guides/developer-guide-adding-transports.md": [
          title: "Developer Guide: Adding Transports"
        ],
        "guides/developer-guide-provider-profiles.md": [
          title: "Developer Guide: Provider Profiles"
        ],
        "guides/command-api.md": [title: "Command API"],
        "guides/raw-transport.md": [title: "Raw Sessions And Transport"],
        "guides/channel-api.md": [title: "Channel API"],
        "guides/json-rpc.md": [title: "JSON-RPC"],
        "guides/session-api.md": [title: "Session API"],
        "guides/shutdown-and-timeouts.md": [title: "Shutdown And Timeouts"],
        "examples/README.md": [title: "Examples", filename: "examples"],
        "guides/testing-and-conformance.md": [title: "Testing And Conformance"]
      ],
      groups_for_extras: [
        "Project Overview": ["README.md"],
        Examples: ["examples/README.md"],
        "Provider Profiles": [
          "guides/provider-profile-contract.md",
          "guides/custom-provider-profiles.md",
          "guides/built-in-provider-profiles.md",
          "guides/provider-feature-manifests.md"
        ],
        "Developer Guides": [
          "guides/developer-guide-model-registry.md",
          "guides/developer-guide-runtime-layers.md",
          "guides/developer-guide-claude-backends.md",
          "guides/developer-guide-codex-backends.md",
          "guides/developer-guide-adding-transports.md",
          "guides/developer-guide-provider-profiles.md"
        ],
        "Runtime & APIs": [
          "guides/getting-started.md",
          "guides/external-runtime-transport.md",
          "guides/execution-surface-compatibility.md",
          "guides/raw-transport.md",
          "guides/event-and-payload-model.md",
          "guides/command-api.md",
          "guides/channel-api.md",
          "guides/json-rpc.md",
          "guides/session-api.md"
        ],
        "Operations & Conformance": [
          "guides/shutdown-and-timeouts.md",
          "guides/testing-and-conformance.md"
        ],
        "Project Reference": ["CHANGELOG.md", "LICENSE"]
      ],
      formatters: ["html", "epub", "markdown"],
      source_url: @source_url
    ]
  end

  defp package do
    [
      name: "cli_subprocess_core",
      description: description(),
      files:
        ~w(lib priv/models scripts .formatter.exs mix.exs mix.lock README* CHANGELOG* LICENSE* AGENTS.md assets),
      licenses: ["MIT"],
      maintainers: ["nshkrdotcom"],
      links: %{
        "GitHub" => @source_url,
        "Hex" => @homepage_url,
        "HexDocs" => @docs_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "License" => "#{@source_url}/blob/main/LICENSE"
      }
    ]
  end

  defp description do
    "Shared CLI subprocess runtime foundation with first-party common provider profiles."
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {CliSubprocessCore.Application, []}
    ]
  end

  defp deps do
    [
      {:execution_plane, path: "../execution_plane"},
      {:external_runtime_transport, "~> 0.1.0"},
      {:jason, "~> 1.4"},
      {:zoi, "~> 0.17"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_core_path: "priv/plts/core",
      plt_local_path: "priv/plts",
      flags: [:error_handling, :underspecs]
    ]
  end
end
