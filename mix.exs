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
      main: "readme",
      source_ref: "v#{@version}",
      homepage_url: @homepage_url,
      assets: %{"assets" => "assets"},
      logo: "assets/cli_subprocess_core.svg",
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"],
        "guides/getting-started.md": [title: "Getting Started"],
        "guides/event-and-payload-model.md": [title: "Event And Payload Model"],
        "guides/provider-profile-contract.md": [title: "Provider Profile Contract"],
        "guides/custom-provider-profiles.md": [title: "Custom Provider Profiles"],
        "guides/built-in-provider-profiles.md": [title: "Built-In Provider Profiles"],
        "guides/command-api.md": [title: "Command API"],
        "guides/raw-transport.md": [title: "Raw Transport"],
        "guides/session-api.md": [title: "Session API"],
        "guides/testing-and-conformance.md": [title: "Testing And Conformance"],
        "guides/shutdown-and-timeouts.md": [title: "Shutdown And Timeouts"]
      ],
      groups_for_extras: [
        "Project Overview": ~r"README\.md",
        "Project Reference": ~r"CHANGELOG\.md|LICENSE",
        Guides: ~r"guides/"
      ],
      formatters: ["html", "epub", "markdown"],
      source_url: @source_url
    ]
  end

  defp package do
    [
      name: "cli_subprocess_core",
      description: description(),
      files: ~w(lib guides .formatter.exs mix.exs mix.lock README* CHANGELOG* LICENSE* assets),
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
      extra_applications: [:logger],
      mod: {CliSubprocessCore.Application, []}
    ]
  end

  defp deps do
    [
      {:erlexec, "~> 2.2"},
      {:jason, "~> 1.4"},
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
      plt_file: {:no_warn, "priv/plts/project.plt"},
      flags: [:error_handling, :underspecs]
    ]
  end
end
