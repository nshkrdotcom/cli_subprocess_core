# `build_support/` is not shipped in the published package, so its absence is
# how this file knows it is running inside a consumer's deps/ rather than in a
# source checkout. Guard on the file, not on a directory shape: a shape test
# breaks when the repo is vendored at a different depth or used as a git dep
# with :subdir.
workspace_helper = Path.expand("build_support/dependency_sources.exs", __DIR__)
workspace_checkout? = File.regular?(workspace_helper)

if workspace_checkout? and not Code.ensure_loaded?(DependencySources) do
  Code.require_file(workspace_helper)
end

defmodule CliSubprocessCore.MixProject do
  use Mix.Project

  @workspace_checkout? File.regular?(Path.expand("build_support/dependency_sources.exs", __DIR__))

  @version "0.7.0"
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
      aliases: aliases(),
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
        "guides/execution-surface-compatibility.md": [title: "Execution Surface Compatibility"],
        "guides/event-and-payload-model.md": [title: "Event And Payload Model"],
        "guides/recovery-envelope.md": [title: "Recovery Envelope"],
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
          "guides/execution-surface-compatibility.md",
          "guides/recovery-envelope.md",
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
      files: ~w(lib priv/models guides examples mix.exs README* CHANGELOG* LICENSE* assets),
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
      extra_applications: [:logger, :inets, :ssl, :crypto],
      mod: {CliSubprocessCore.Application, []}
    ]
  end

  def cli do
    [preferred_envs: ["test.live": :test]]
  end

  defp deps do
    execution_plane = execution_plane_dep()

    [execution_plane, execution_plane_process_dep(), execution_plane_jsonrpc_dep()] ++
      local_ground_overrides(execution_plane) ++
      [
        {:jason, "~> 1.4"},
        {:zoi, "~> 0.18"},
        {:ex_doc, "~> 0.40", only: :dev, runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: :dev, runtime: false}
      ]
  end

  defp execution_plane_dep, do: workspace_dep(:execution_plane, "~> 0.3.0")

  defp execution_plane_process_dep,
    do: workspace_dep(:execution_plane_process, "~> 0.3.0")

  defp execution_plane_jsonrpc_dep,
    do: workspace_dep(:execution_plane_jsonrpc, "~> 0.2.0")

  # In a source checkout the registry decides the source (path first). In a
  # published package there is no registry, and the requirement stated here is
  # the whole answer.
  defp workspace_dep(app, hex_requirement) do
    if @workspace_checkout? do
      apply(DependencySources, :dep, [app, __DIR__])
    else
      {app, hex_requirement}
    end
  end

  # The Execution Plane core package declares ordinary Hex Ground
  # dependencies. Until those parents are published, local and source
  # consumers override them at the top level. Hex mode omits these entries, so
  # they never enter the published CLI package dependency surface.
  defp local_ground_overrides({:execution_plane, opts}) when is_list(opts) do
    if @workspace_checkout? and local_ground_paths_available?() do
      [
        apply(DependencySources, :dep, [:ground_plane_contracts, __DIR__, [override: true]]),
        apply(DependencySources, :dep, [
          :ground_plane_persistence_policy,
          __DIR__,
          [override: true]
        ])
      ]
    else
      []
    end
  end

  defp local_ground_overrides(_execution_plane), do: []

  defp local_ground_paths_available? do
    File.dir?(Path.expand("../ground_plane/core/ground_plane_contracts", __DIR__)) and
      File.dir?(Path.expand("../ground_plane/core/persistence_policy", __DIR__))
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_core_path: "priv/plts/core",
      plt_local_path: "priv/plts",
      flags: [:error_handling, :underspecs]
    ]
  end

  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "cmd ./scripts/atom_guard.sh",
        "cmd ./scripts/secrets_guard.sh",
        "credo --strict",
        "cmd env MIX_ENV=test mix test",
        "dialyzer"
      ],
      "test.live": ["test --include live"]
    ]
  end
end
