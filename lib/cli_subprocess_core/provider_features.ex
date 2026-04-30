defmodule CliSubprocessCore.ProviderFeatures do
  @moduledoc """
  Canonical provider feature metadata for the built-in CLI profiles.

  This module is the public, authoritative source for:

  - provider-native permission mode terminology and CLI flag rendering
  - provider-local partial features such as Ollama-backed model routing
  - decomposed tool capability metadata for normalized observation versus
    unadmitted host execution
  """

  @type permission_manifest :: %{
          native_mode: atom(),
          cli_args: [String.t()],
          cli_excerpt: String.t() | nil,
          label: String.t()
        }

  @type partial_feature_manifest :: %{
          supported?: boolean(),
          activation: map() | nil,
          model_strategy: atom() | nil,
          compatibility: map() | nil,
          notes: [String.t()]
        }

  @type tool_capability_key ::
          :tool_events
          | :tool_results
          | :host_tools
          | :tool_allowlist
          | :tool_denylist
          | :mcp_servers
          | :provider_builtin_tools
          | :no_tool_mode

  @type tool_capability_value :: boolean() | :unknown

  @type tool_capability_manifest :: %{
          required(tool_capability_key()) => tool_capability_value(),
          optional(:notes) => [String.t()]
        }

  @type manifest :: %{
          provider: atom(),
          permission_modes: %{optional(atom()) => permission_manifest()},
          partial_features: %{optional(atom()) => partial_feature_manifest()},
          tool_capabilities: tool_capability_manifest()
        }

  @tool_capability_keys [
    :tool_events,
    :tool_results,
    :host_tools,
    :tool_allowlist,
    :tool_denylist,
    :mcp_servers,
    :provider_builtin_tools,
    :no_tool_mode
  ]

  @observed_tool_capabilities %{
    tool_events: true,
    tool_results: true,
    host_tools: false,
    tool_allowlist: :unknown,
    tool_denylist: :unknown,
    mcp_servers: :unknown,
    provider_builtin_tools: :unknown,
    no_tool_mode: :unknown
  }

  @manifests %{
    amp: %{
      provider: :amp,
      permission_modes: %{
        default: %{native_mode: :default, cli_args: [], cli_excerpt: nil, label: "default"},
        auto: %{native_mode: :auto, cli_args: [], cli_excerpt: nil, label: "auto"},
        plan: %{native_mode: :plan, cli_args: [], cli_excerpt: nil, label: "plan"},
        dangerously_allow_all: %{
          native_mode: :dangerously_allow_all,
          cli_args: ["--dangerously-allow-all"],
          cli_excerpt: "--dangerously-allow-all",
          label: "dangerously_allow_all"
        }
      },
      partial_features: %{
        ollama: %{
          supported?: false,
          activation: nil,
          model_strategy: nil,
          compatibility: nil,
          notes: ["Amp does not expose an Ollama backend through the common CLI surface."]
        }
      },
      tool_capabilities:
        Map.put(@observed_tool_capabilities, :notes, [
          "The Amp profile normalizes observed tool_use/tool_result events from JSONL.",
          "Amp host tool execution, MCP configuration, explicit tool lists, and tool suppression remain provider-native or unproven at the core contract."
        ])
    },
    claude: %{
      provider: :claude,
      permission_modes: %{
        default: %{
          native_mode: :default,
          cli_args: ["--permission-mode", "default"],
          cli_excerpt: "--permission-mode default",
          label: "default"
        },
        accept_edits: %{
          native_mode: :accept_edits,
          cli_args: ["--permission-mode", "acceptEdits"],
          cli_excerpt: "--permission-mode acceptEdits",
          label: "acceptEdits"
        },
        delegate: %{
          native_mode: :delegate,
          cli_args: ["--permission-mode", "delegate"],
          cli_excerpt: "--permission-mode delegate",
          label: "delegate"
        },
        dont_ask: %{
          native_mode: :dont_ask,
          cli_args: ["--permission-mode", "dontAsk"],
          cli_excerpt: "--permission-mode dontAsk",
          label: "dontAsk"
        },
        bypass_permissions: %{
          native_mode: :bypass_permissions,
          cli_args: ["--permission-mode", "bypassPermissions"],
          cli_excerpt: "--permission-mode bypassPermissions",
          label: "bypassPermissions"
        },
        plan: %{
          native_mode: :plan,
          cli_args: ["--permission-mode", "plan"],
          cli_excerpt: "--permission-mode plan",
          label: "plan"
        }
      },
      partial_features: %{
        ollama: %{
          supported?: true,
          activation: %{provider_backend: :ollama},
          model_strategy: :canonical_or_direct_external,
          compatibility: nil,
          notes: [
            "Claude/Ollama can run a direct external model id or keep canonical Claude names mapped via external_model_overrides.",
            "Claude/Ollama has no silent default model; callers must provide model intent."
          ]
        }
      },
      tool_capabilities:
        Map.put(@observed_tool_capabilities, :notes, [
          "The Claude profile normalizes observed tool_use/tool_result events from stream-json output.",
          "Claude tool allow/deny lists, MCP, built-ins, and host execution remain provider-native or unproven at the core contract."
        ])
    },
    codex: %{
      provider: :codex,
      permission_modes: %{
        default: %{native_mode: :default, cli_args: [], cli_excerpt: nil, label: "default"},
        auto_edit: %{
          native_mode: :auto_edit,
          cli_args: ["--full-auto"],
          cli_excerpt: "--full-auto",
          label: "full-auto"
        },
        yolo: %{
          native_mode: :yolo,
          cli_args: ["--dangerously-bypass-approvals-and-sandbox"],
          cli_excerpt: "--dangerously-bypass-approvals-and-sandbox",
          label: "yolo"
        },
        plan: %{native_mode: :plan, cli_args: ["--plan"], cli_excerpt: "--plan", label: "plan"}
      },
      partial_features: %{
        ollama: %{
          supported?: true,
          activation: %{provider_backend: :oss, oss_provider: "ollama"},
          model_strategy: :direct_external,
          compatibility: %{
            acceptance: :runtime_validated_external_model,
            default_model: "gpt-oss:20b",
            validated_models: ["gpt-oss:20b"]
          },
          notes: [
            "Codex/Ollama uses OSS routing with oss_provider=ollama.",
            "Codex/Ollama model selection uses the direct external model id.",
            "Any Ollama model that the upstream Codex CLI can start is allowed on the shared route.",
            "gpt-oss:20b remains the default validated Codex/Ollama example and default OSS bootstrap target.",
            "Non-catalog models may run with upstream fallback metadata, which can degrade behavior."
          ]
        }
      },
      tool_capabilities:
        Map.put(@observed_tool_capabilities, :notes, [
          "The Codex profile normalizes observed tool_use/tool_result events from JSONL output.",
          "Codex app-server, dynamic tools, MCP, built-ins, and host execution remain provider-native or unproven at the core contract."
        ])
    },
    gemini: %{
      provider: :gemini,
      permission_modes: %{
        default: %{native_mode: :default, cli_args: [], cli_excerpt: nil, label: "default"},
        auto_edit: %{
          native_mode: :auto_edit,
          cli_args: ["--approval-mode", "auto_edit"],
          cli_excerpt: "--approval-mode auto_edit",
          label: "auto_edit"
        },
        plan: %{
          native_mode: :plan,
          cli_args: ["--approval-mode", "plan"],
          cli_excerpt: "--approval-mode plan",
          label: "plan"
        },
        yolo: %{native_mode: :yolo, cli_args: ["--yolo"], cli_excerpt: "--yolo", label: "yolo"}
      },
      partial_features: %{
        ollama: %{
          supported?: false,
          activation: nil,
          model_strategy: nil,
          compatibility: nil,
          notes: ["Gemini does not expose an Ollama backend through the common CLI surface."]
        }
      },
      tool_capabilities:
        Map.put(@observed_tool_capabilities, :notes, [
          "The Gemini profile normalizes observed tool_use/tool_result events from stream-json output.",
          "Gemini extensions, settings, tool allowlists, and no-tool/plain-response behavior remain provider-native or unproven at the core contract."
        ])
    }
  }

  @spec manifest(atom()) :: {:ok, manifest()} | :error
  def manifest(provider) when is_atom(provider) do
    case Map.fetch(@manifests, canonical_provider(provider)) do
      {:ok, manifest} -> {:ok, manifest}
      :error -> :error
    end
  end

  @spec manifest!(atom()) :: manifest()
  def manifest!(provider) when is_atom(provider) do
    case manifest(provider) do
      {:ok, manifest} -> manifest
      :error -> raise ArgumentError, "unknown built-in provider #{inspect(provider)}"
    end
  end

  @spec permission_mode(atom(), atom() | String.t()) :: {:ok, permission_manifest()} | :error
  def permission_mode(provider, mode) when is_atom(provider) do
    provider
    |> manifest()
    |> case do
      {:ok, %{permission_modes: permission_modes}} ->
        find_permission_mode(permission_modes, mode)

      :error ->
        :error
    end
  end

  @spec permission_mode!(atom(), atom() | String.t()) :: permission_manifest()
  def permission_mode!(provider, mode) do
    case permission_mode(provider, mode) do
      {:ok, manifest} ->
        manifest

      :error ->
        raise ArgumentError, "unknown permission mode #{inspect(mode)} for #{inspect(provider)}"
    end
  end

  @spec permission_args(atom(), atom() | String.t()) :: [String.t()]
  def permission_args(provider, mode) do
    case permission_mode(provider, mode) do
      {:ok, %{cli_args: cli_args}} -> cli_args
      :error -> []
    end
  end

  @spec partial_feature(atom(), atom()) :: {:ok, partial_feature_manifest()} | :error
  def partial_feature(provider, feature) when is_atom(provider) and is_atom(feature) do
    provider
    |> manifest()
    |> case do
      {:ok, %{partial_features: partial_features}} -> Map.fetch(partial_features, feature)
      :error -> :error
    end
  end

  @spec partial_feature!(atom(), atom()) :: partial_feature_manifest()
  def partial_feature!(provider, feature) do
    case partial_feature(provider, feature) do
      {:ok, manifest} ->
        manifest

      :error ->
        raise ArgumentError,
              "unknown partial feature #{inspect(feature)} for #{inspect(provider)}"
    end
  end

  @doc """
  Returns decomposed tool capability metadata for a built-in provider.

  `:tool_events` and `:tool_results` describe normalized observation payloads
  emitted by the core provider profiles. They do not imply host-executable tool
  registration, provider-native tool configuration, or tool suppression.
  """
  @spec tool_capabilities(atom()) :: {:ok, tool_capability_manifest()} | :error
  def tool_capabilities(provider) when is_atom(provider) do
    provider
    |> manifest()
    |> case do
      {:ok, %{tool_capabilities: tool_capabilities}} -> {:ok, tool_capabilities}
      :error -> :error
    end
  end

  @spec tool_capabilities!(atom()) :: tool_capability_manifest()
  def tool_capabilities!(provider) when is_atom(provider) do
    case tool_capabilities(provider) do
      {:ok, tool_capabilities} ->
        tool_capabilities

      :error ->
        raise ArgumentError, "unknown tool capabilities for #{inspect(provider)}"
    end
  end

  @spec tool_capability(atom(), tool_capability_key()) ::
          {:ok, tool_capability_value()} | :error
  def tool_capability(provider, capability)
      when is_atom(provider) and capability in @tool_capability_keys do
    provider
    |> tool_capabilities()
    |> case do
      {:ok, tool_capabilities} -> Map.fetch(tool_capabilities, capability)
      :error -> :error
    end
  end

  @spec tool_capability!(atom(), tool_capability_key()) :: tool_capability_value()
  def tool_capability!(provider, capability) do
    case tool_capability(provider, capability) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "unknown tool capability #{inspect(capability)} for #{inspect(provider)}"
    end
  end

  @doc """
  Returns the required decomposed tool capability keys.
  """
  @spec tool_capability_keys() :: nonempty_list(tool_capability_key())
  def tool_capability_keys, do: @tool_capability_keys

  defp canonical_provider(:codex_exec), do: :codex
  defp canonical_provider(provider), do: provider

  defp find_permission_mode(permission_modes, mode) when is_atom(mode) do
    Map.fetch(permission_modes, mode)
  end

  defp find_permission_mode(permission_modes, mode) when is_binary(mode) do
    normalized = mode |> String.trim() |> String.downcase()

    Enum.find_value(permission_modes, :error, fn {_native_mode, manifest} ->
      if normalized in permission_aliases(manifest) do
        {:ok, manifest}
      else
        false
      end
    end)
  end

  defp find_permission_mode(_permission_modes, _mode), do: :error

  defp permission_aliases(%{native_mode: native_mode, label: label, cli_excerpt: cli_excerpt}) do
    [
      Atom.to_string(native_mode),
      normalize_label(label),
      normalize_label(cli_excerpt)
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp normalize_label(nil), do: nil

  defp normalize_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end
end
