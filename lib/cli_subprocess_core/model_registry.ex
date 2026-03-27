defmodule CliSubprocessCore.ModelRegistry do
  @moduledoc "Canonical model resolution, validation, and argument payload construction."

  alias CliSubprocessCore.ModelCatalog
  alias CliSubprocessCore.ModelRegistry.{Model, Selection}
  alias CliSubprocessCore.Ollama
  alias CliSubprocessCore.ProviderFeatures

  @type resolution_error ::
          {:unknown_model, String.t() | nil, [String.t()], atom()}
          | {:invalid_reasoning_effort, term(), [String.t()] | [number()], atom()}
          | {:model_unavailable, atom(), term()}
          | {:empty_or_invalid_model, String.t(), atom()}

  @type selection :: Selection.t()
  @type model :: Model.t()
  @type provider_backend :: :anthropic | :ollama | atom()

  @invalid_model_inputs ["", "nil", "null"]
  @codex_external_reasonings ~w(none minimal low medium high xhigh)
  @codex_oss_default_model "gpt-oss:20b"
  @ollama_min_responses_version "0.13.4"
  @all_visibilities [:public, :private, :internal, :restricted]
  @visibility_filters %{
    all: @all_visibilities,
    public: [:public],
    private: [:private],
    internal: [:internal],
    restricted: [:restricted],
    default: [:public]
  }

  @spec resolve(atom(), String.t() | nil, keyword()) ::
          {:ok, Selection.t()} | {:error, resolution_error()}
  def resolve(provider, requested_model, opts \\ []) when is_list(opts) do
    provider = normalize_provider(provider)
    provider_backend = resolve_provider_backend(provider, opts)

    with {:ok, catalog} <- load_catalog(provider),
         {:ok, candidate, source, payload_requested} <-
           pick_request_source(catalog, requested_model, opts, provider, provider_backend),
         {:ok, model} <-
           validate(provider, validation_request(candidate, provider_backend, opts)),
         payload_attrs <- selection_payload_attrs(model, provider_backend, candidate, opts),
         {:ok, reasoning_payload} <- resolve_reasoning_payload(model, provider, opts) do
      {:ok,
       Selection.new(%{
         provider: provider,
         requested_model: payload_requested,
         resolved_model: payload_attrs.resolved_model,
         resolution_source: source,
         reasoning: reasoning_payload.reasoning,
         reasoning_effort: reasoning_payload.reasoning_effort,
         normalized_reasoning_effort: reasoning_payload.normalized_reasoning_effort,
         model_family: payload_attrs.model_family,
         catalog_version: payload_attrs.catalog_version || catalog.catalog_version,
         visibility: payload_attrs.visibility,
         provider_backend: provider_backend,
         model_source: payload_attrs.model_source,
         env_overrides: payload_attrs.env_overrides,
         settings_patch: payload_attrs.settings_patch,
         backend_metadata: payload_attrs.backend_metadata,
         errors: []
       })}
    end
  end

  @spec list_visible(atom(), keyword()) ::
          {:ok, [String.t()]} | {:error, {:model_unavailable, atom(), term()}}
  def list_visible(provider, opts \\ []) when is_list(opts) do
    provider = normalize_provider(provider)
    provider_backend = resolve_provider_backend(provider, opts)
    visibility = Keyword.get(opts, :visibility, :public)
    family = normalize_optional_binary(Keyword.get(opts, :model_family))

    case {provider, provider_backend} do
      {:claude, :ollama} ->
        Ollama.list_model_names(opts)

      {:codex, :oss} ->
        case resolve_codex_oss_provider(provider, opts) do
          {:ok, "ollama"} ->
            Ollama.list_model_names(ollama_opts(opts))

          {:error, _reason} = error ->
            error
        end

      _other ->
        list_catalog_visible(provider, visibility, family)
    end
  end

  @spec default_model(atom(), keyword()) ::
          {:ok, String.t()} | {:error, {:model_unavailable, atom(), term()}}
  def default_model(provider, opts \\ []) when is_list(opts) do
    provider = normalize_provider(provider)
    provider_backend = resolve_provider_backend(provider, opts)

    case {provider, provider_backend} do
      {:claude, :ollama} ->
        {:error, {:model_unavailable, provider, :no_external_model_default}}

      {:codex, :oss} ->
        with {:ok, "ollama"} <- resolve_codex_oss_provider(provider, opts) do
          {:ok, @codex_oss_default_model}
        end

      _other ->
        default_catalog_model(provider)
    end
  end

  @spec validate(atom(), String.t() | atom() | keyword() | map() | nil) ::
          {:ok, Model.t()} | {:error, resolution_error()}
  def validate(provider, requested_model)
      when is_binary(requested_model) or is_atom(requested_model) do
    provider = normalize_provider(provider)

    do_validate(
      provider,
      validation_request(requested_model, resolve_provider_backend(provider, []), [])
    )
  end

  def validate(provider, request) when is_list(request) or is_map(request) do
    provider = normalize_provider(provider)
    do_validate(provider, parse_validation_request(request, provider))
  end

  def validate(provider, nil) do
    {:error,
     {:empty_or_invalid_model, "requested model is missing", normalize_provider(provider)}}
  end

  defp do_validate(:claude, %{provider_backend: :ollama} = request) do
    with {:ok, requested_model} <- normalize_requested_model(request.model, :explicit, :claude),
         {:ok, catalog} <- load_catalog(:claude),
         external_model <- external_claude_model(requested_model, request, catalog.models),
         {:ok, details} <- Ollama.validate_model(external_model, :claude, ollama_opts(request)) do
      build_external_claude_model(requested_model, external_model, details)
    end
  end

  defp do_validate(:codex, %{provider_backend: :oss} = request) do
    with {:ok, "ollama"} <- resolve_codex_oss_provider(:codex, request),
         {:ok, requested_model} <- normalize_requested_model(request.model, :explicit, :codex),
         {:ok, ollama_version} <- ensure_ollama_responses_supported(:codex, ollama_opts(request)),
         {:ok, details} <- Ollama.validate_model(requested_model, :codex, ollama_opts(request)) do
      running_models =
        case Ollama.running_models(ollama_opts(request)) do
          {:ok, models} -> models
          {:error, _reason} -> []
        end

      build_external_codex_model(requested_model, details, running_models, ollama_version)
    end
  end

  defp do_validate(provider, %{model: requested_model}) do
    with {:ok, catalog} <- load_catalog(provider),
         {:ok, normalized_requested} <-
           normalize_requested_model(requested_model, :explicit, provider) do
      find_model(catalog.models, normalized_requested, provider)
    end
  end

  @spec normalize_reasoning_effort(atom(), Model.t() | String.t(), term()) ::
          {:ok,
           %{
             reasoning: String.t() | nil,
             reasoning_effort: number() | nil,
             normalized_reasoning_effort: number() | nil
           }}
          | {:error, {:invalid_reasoning_effort, term(), [String.t()] | [number()], atom()}}
  def normalize_reasoning_effort(provider, %Model{} = model, requested_reasoning) do
    provider = normalize_provider(provider)

    case resolve_reasoning_payload(model, provider, reasoning: requested_reasoning) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, {:invalid_reasoning_effort, _, _allowed, _}} = error ->
        error
    end
  end

  def normalize_reasoning_effort(provider, model_id, requested_reasoning)
      when is_binary(model_id) do
    provider = normalize_provider(provider)

    with {:ok, catalog} <- load_catalog(provider),
         {:ok, model} <- find_model(catalog.models, model_id, provider) do
      normalize_reasoning_effort(provider, model, requested_reasoning)
    end
  end

  def normalize_reasoning_effort(_provider, _model_id, _requested_reasoning) do
    {:ok, %{reasoning: nil, reasoning_effort: nil, normalized_reasoning_effort: nil}}
  end

  @doc "Builds the resolved payload used by downstream CLI renderers."
  @spec build_arg_payload(atom(), String.t() | nil, keyword()) ::
          {:ok, Selection.t()} | {:error, resolution_error()}
  def build_arg_payload(provider, requested_model, opts \\ []) when is_list(opts) do
    resolve(provider, requested_model, opts)
  end

  defp resolve_reasoning_payload(
         %Model{provider: :codex, metadata: %{"backend" => "ollama"}},
         provider,
         opts
       ) do
    requested_reasoning = Keyword.get(opts, :reasoning_effort, Keyword.get(opts, :reasoning))

    case normalize_external_codex_reasoning(requested_reasoning) do
      {:ok, reasoning} ->
        {:ok, %{reasoning: reasoning, reasoning_effort: nil, normalized_reasoning_effort: nil}}

      {:error, allowed} ->
        {:error, {:invalid_reasoning_effort, requested_reasoning, allowed, provider}}
    end
  end

  defp resolve_reasoning_payload(%Model{} = model, provider, opts) do
    requested_reasoning = Keyword.get(opts, :reasoning_effort, Keyword.get(opts, :reasoning))

    case resolve_reasoning(model, requested_reasoning) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, allowed} ->
        {:error, {:invalid_reasoning_effort, requested_reasoning, allowed, provider}}
    end
  end

  defp resolve_reasoning(%Model{} = model, nil) do
    case model.default_reasoning_effort do
      nil ->
        {:ok, %{reasoning: nil, reasoning_effort: nil, normalized_reasoning_effort: nil}}

      reasoning ->
        effort = Map.get(model.reasoning_efforts, reasoning)

        {:ok,
         %{reasoning: reasoning, reasoning_effort: effort, normalized_reasoning_effort: effort}}
    end
  end

  defp resolve_reasoning(%Model{} = model, requested_reasoning) do
    normalized = normalize_reasoning_input(requested_reasoning)

    case normalized do
      {:reasoning, value} ->
        case Map.fetch(model.reasoning_efforts, value) do
          {:ok, effort} ->
            {:ok,
             %{reasoning: value, reasoning_effort: effort, normalized_reasoning_effort: effort}}

          :error ->
            {:error, Map.keys(model.reasoning_efforts)}
        end

      {:number, value} ->
        case find_reasoning_label_for_number(model.reasoning_efforts, value) do
          {reasoning, effort} ->
            {:ok,
             %{
               reasoning: reasoning,
               reasoning_effort: effort,
               normalized_reasoning_effort: effort
             }}

          nil ->
            {:error, Map.keys(model.reasoning_efforts)}
        end

      :invalid ->
        {:error, Map.keys(model.reasoning_efforts)}

      :skip ->
        resolve_reasoning(model, nil)
    end
  end

  defp find_reasoning_label_for_number(reasoning_efforts, requested_value) do
    Enum.find_value(reasoning_efforts, fn
      {reasoning, effort} when is_number(effort) and effort == requested_value ->
        {reasoning, effort}

      _ ->
        nil
    end)
  end

  defp normalize_reasoning_input(nil), do: :skip

  defp normalize_reasoning_input(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.trim()
    |> normalize_reasoning_input()
  end

  defp normalize_reasoning_input(value) when is_binary(value) do
    normalized = String.downcase(String.trim(value))

    case normalized in @invalid_model_inputs do
      true -> :skip
      false -> {:reasoning, normalized}
    end
  end

  defp normalize_reasoning_input(value) when is_number(value) do
    {:number, value}
  end

  defp normalize_reasoning_input(_other), do: :invalid

  defp pick_request_source(catalog, requested_model, opts, provider, provider_backend) do
    case normalize_requested_model_maybe(requested_model, :explicit, provider) do
      {:ok, candidate} ->
        {:ok, candidate, :explicit, candidate}

      {:skip} ->
        pick_env_or_default(catalog, env_model_from_opts(opts), provider, provider_backend, opts)

      {:error, _} = error ->
        error
    end
  end

  defp pick_env_or_default(catalog, env_model, provider, provider_backend, opts) do
    case normalize_requested_model_maybe(env_model, :env, provider) do
      {:ok, candidate} ->
        {:ok, candidate, :env, candidate}

      {:skip} ->
        pick_default_or_remote(catalog, provider, provider_backend, opts)

      {:error, _} = error ->
        error
    end
  end

  defp pick_default_or_remote(_catalog, provider, :ollama, _opts) when provider == :claude do
    {:error, {:model_unavailable, provider, :no_external_model_default}}
  end

  defp pick_default_or_remote(_catalog, provider, :oss, opts) when provider == :codex do
    with {:ok, "ollama"} <- resolve_codex_oss_provider(provider, opts) do
      {:ok, @codex_oss_default_model, :default, nil}
    end
  end

  defp pick_default_or_remote(catalog, provider, _provider_backend, _opts) do
    case default_model_from_catalog(catalog, provider) do
      {:ok, model} ->
        {:ok, model.id, :default, nil}

      {:error, _} ->
        case catalog_remote_default(catalog, provider) do
          {:ok, remote} -> {:ok, remote, :remote, nil}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp catalog_remote_default(catalog, provider) do
    case catalog.remote_default do
      nil ->
        {:error, {:model_unavailable, provider, :no_default_or_remote_model}}

      remote_default ->
        case normalize_requested_model(remote_default, :remote, provider) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp env_model_from_opts(opts) do
    Keyword.get(opts, :model_env) ||
      Keyword.get(opts, :env_model) ||
      Keyword.get(opts, :environment_model)
  end

  defp normalize_requested_model_maybe(nil, _source, _provider), do: {:skip}

  defp normalize_requested_model_maybe(value, source, provider) do
    normalize_requested_model(value, source, provider)
  end

  defp normalize_requested_model(value, source_name, provider) when is_binary(value) do
    normalized = String.trim(value)

    cond do
      normalized == "" ->
        {:error, {:empty_or_invalid_model, "#{source_name} model is empty", provider}}

      normalized in @invalid_model_inputs ->
        {:error, {:empty_or_invalid_model, "#{source_name} model is empty or invalid", provider}}

      true ->
        {:ok, normalized}
    end
  end

  defp normalize_requested_model(value, source_name, provider) when is_atom(value) do
    normalize_requested_model(Atom.to_string(value), source_name, provider)
  end

  defp normalize_requested_model(_value, source_name, provider) do
    {:error, {:empty_or_invalid_model, "#{source_name} model is empty or invalid", provider}}
  end

  defp find_model(models, requested_model, provider) when is_binary(requested_model) do
    Enum.find_value(models, fn model ->
      if Model.matches_id_or_alias?(model, requested_model) do
        model
      end
    end)
    |> case do
      nil ->
        {:error, {:unknown_model, requested_model, Enum.map(models, & &1.id), provider}}

      %Model{} = model ->
        {:ok, model}
    end
  end

  defp load_catalog(provider) when is_atom(provider) do
    ModelCatalog.load(provider)
  end

  defp list_catalog_visible(provider, visibility, family) do
    with {:ok, catalog} <- load_catalog(provider),
         {:ok, filters} <- expand_visibility_filter(visibility) do
      visible =
        catalog.models
        |> Enum.filter(fn model ->
          model.visibility in filters and (family == nil or model.family == family)
        end)
        |> Enum.map(& &1.id)

      {:ok, visible}
    end
  end

  defp default_catalog_model(provider) do
    with {:ok, catalog} <- load_catalog(provider) do
      case default_model_from_catalog(catalog, provider) do
        {:ok, model} -> {:ok, model.id}
        {:error, _reason} -> catalog_remote_default(catalog, provider)
      end
    end
  end

  defp validation_request(model, provider_backend, opts) do
    %{
      model: model,
      provider_backend: provider_backend,
      model_provider: Keyword.get(opts, :model_provider),
      oss_provider: Keyword.get(opts, :oss_provider),
      external_model_overrides: Keyword.get(opts, :external_model_overrides, %{}),
      anthropic_base_url: Keyword.get(opts, :anthropic_base_url),
      ollama_base_url: Keyword.get(opts, :ollama_base_url),
      anthropic_auth_token: Keyword.get(opts, :anthropic_auth_token),
      ollama_http: Keyword.get(opts, :ollama_http),
      ollama_timeout_ms: Keyword.get(opts, :ollama_timeout_ms)
    }
  end

  defp parse_validation_request(request, provider) do
    request = Enum.into(request, %{})

    %{
      model: Map.get(request, :model, Map.get(request, "model")),
      provider_backend:
        resolve_provider_backend(
          provider,
          provider_backend:
            Map.get(request, :provider_backend, Map.get(request, "provider_backend"))
        ),
      model_provider: Map.get(request, :model_provider, Map.get(request, "model_provider")),
      oss_provider: Map.get(request, :oss_provider, Map.get(request, "oss_provider")),
      external_model_overrides:
        Map.get(
          request,
          :external_model_overrides,
          Map.get(request, "external_model_overrides", %{})
        ),
      anthropic_base_url:
        Map.get(request, :anthropic_base_url, Map.get(request, "anthropic_base_url")),
      ollama_base_url: Map.get(request, :ollama_base_url, Map.get(request, "ollama_base_url")),
      anthropic_auth_token:
        Map.get(request, :anthropic_auth_token, Map.get(request, "anthropic_auth_token")),
      ollama_http: Map.get(request, :ollama_http, Map.get(request, "ollama_http")),
      ollama_timeout_ms:
        Map.get(request, :ollama_timeout_ms, Map.get(request, "ollama_timeout_ms"))
    }
  end

  defp selection_payload_attrs(%Model{} = model, :ollama, requested_model, opts)
       when model.provider == :claude do
    %{
      resolved_model: model.id,
      model_family: model.family,
      catalog_version: nil,
      visibility: :public,
      model_source: :external,
      env_overrides: external_claude_env_overrides(opts),
      settings_patch: %{},
      backend_metadata:
        model.metadata
        |> Map.put_new("requested_model", requested_model)
        |> Map.put_new("provider_backend", "ollama")
    }
  end

  defp selection_payload_attrs(%Model{} = model, :oss, requested_model, opts)
       when model.provider == :codex do
    %{
      resolved_model: model.id,
      model_family: model.family,
      catalog_version: nil,
      visibility: :public,
      model_source: :external,
      env_overrides: external_codex_env_overrides(opts),
      settings_patch: %{},
      backend_metadata:
        model.metadata
        |> Map.put_new("requested_model", requested_model)
        |> Map.put_new("provider_backend", "oss")
        |> Map.put_new("oss_provider", "ollama")
    }
  end

  defp selection_payload_attrs(%Model{} = model, :model_provider, requested_model, opts)
       when model.provider == :codex do
    %{
      resolved_model: model.id,
      model_family: model.family,
      catalog_version: model.catalog_version,
      visibility: model.visibility,
      model_source: :catalog,
      env_overrides: %{},
      settings_patch: %{},
      backend_metadata:
        %{}
        |> maybe_put_metadata("requested_model", requested_model)
        |> maybe_put_metadata("provider_backend", "model_provider")
        |> maybe_put_metadata("model_provider", Keyword.get(opts, :model_provider))
    }
  end

  defp selection_payload_attrs(%Model{} = model, _provider_backend, _requested_model, _opts) do
    %{
      resolved_model: model.id,
      model_family: model.family,
      catalog_version: model.catalog_version,
      visibility: model.visibility,
      model_source: :catalog,
      env_overrides: %{},
      settings_patch: %{},
      backend_metadata: %{}
    }
  end

  defp external_claude_env_overrides(opts) do
    %{
      "ANTHROPIC_AUTH_TOKEN" => Keyword.get(opts, :anthropic_auth_token, "ollama") |> to_string(),
      "ANTHROPIC_API_KEY" => "",
      "ANTHROPIC_BASE_URL" =>
        Keyword.get(opts, :anthropic_base_url, Ollama.default_base_url()) |> to_string()
    }
  end

  defp external_codex_env_overrides(opts) do
    case Keyword.get(opts, :ollama_base_url) do
      value when is_binary(value) and value != "" ->
        %{"CODEX_OSS_BASE_URL" => value}

      _other ->
        %{}
    end
  end

  defp external_claude_model(requested_model, request, models) when is_binary(requested_model) do
    overrides = normalize_external_model_overrides(request.external_model_overrides)

    case Enum.find(models, &Model.matches_id_or_alias?(&1, requested_model)) do
      %Model{id: model_id, aliases: aliases} ->
        ([model_id | aliases] ++ [requested_model])
        |> Enum.find_value(requested_model, &Map.get(overrides, &1))

      nil ->
        Map.get(overrides, requested_model, requested_model)
    end
  end

  defp normalize_external_model_overrides(overrides) when is_map(overrides) do
    Map.new(overrides, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_external_model_overrides(_other), do: %{}

  defp build_external_claude_model(requested_model, external_model, details) do
    metadata = %{
      "backend" => "ollama",
      "requested_model" => requested_model,
      "external_model" => external_model,
      "capabilities" => Map.get(details, "capabilities", []),
      "modified_at" => Map.get(details, "modified_at"),
      "details" => Map.get(details, "details", %{})
    }

    Model.new(:claude, %{
      id: external_model,
      aliases:
        [requested_model]
        |> Enum.reject(&(&1 == external_model))
        |> Enum.uniq(),
      visibility: :public,
      family: ollama_model_family(details),
      metadata: metadata
    })
  end

  defp build_external_codex_model(requested_model, details, running_models, ollama_version) do
    support_tier = codex_ollama_support_tier(requested_model)

    metadata =
      %{
        "backend" => "ollama",
        "oss_provider" => "ollama",
        "requested_model" => requested_model,
        "external_model" => requested_model,
        "support_tier" => support_tier,
        "capabilities" => Map.get(details, "capabilities", []),
        "modified_at" => Map.get(details, "modified_at"),
        "details" => Map.get(details, "details", %{}),
        "ollama_version" => ollama_version,
        "loaded" => ollama_model_loaded?(requested_model, running_models)
      }
      |> maybe_put_metadata("context_length", ollama_context_length(details))
      |> maybe_put_metadata("parameter_size", ollama_parameter_size(details))
      |> maybe_put_metadata("quantization_level", ollama_quantization_level(details))

    Model.new(:codex, %{
      id: requested_model,
      visibility: :public,
      family: ollama_model_family(details),
      reasoning_efforts: Map.new(@codex_external_reasonings, &{&1, nil}),
      default_reasoning_effort: "high",
      metadata: metadata
    })
  end

  defp ollama_model_family(details) when is_map(details) do
    details
    |> Map.get("details", %{})
    |> Map.get("family")
  end

  defp ollama_context_length(details) when is_map(details) do
    Map.get(details, "context_length") ||
      get_in(details, ["details", "context_length"]) ||
      ollama_model_info_value(details, ".context_length")
  end

  defp ollama_parameter_size(details) when is_map(details) do
    get_in(details, ["details", "parameter_size"]) ||
      Map.get(details, "parameter_size")
  end

  defp ollama_quantization_level(details) when is_map(details) do
    get_in(details, ["details", "quantization_level"]) ||
      Map.get(details, "quantization_level")
  end

  defp ollama_model_info_value(details, suffix) when is_binary(suffix) do
    details
    |> Map.get("model_info", %{})
    |> Enum.find_value(fn
      {key, value} when is_binary(key) and is_integer(value) ->
        if String.ends_with?(key, suffix), do: value

      _ ->
        nil
    end)
  end

  defp ollama_model_loaded?(requested_model, running_models) when is_list(running_models) do
    Enum.any?(running_models, fn
      %{"name" => model_name} ->
        same_external_model?(model_name, requested_model)

      %{"model" => model_name} ->
        same_external_model?(model_name, requested_model)

      _ ->
        false
    end)
  end

  defp same_external_model?(left, right) when is_binary(left) and is_binary(right) do
    normalize_external_model_name(left) == normalize_external_model_name(right)
  end

  defp normalize_external_model_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.trim_trailing(":latest")
  end

  defp codex_ollama_compatibility do
    :codex
    |> ProviderFeatures.partial_feature!(:ollama)
    |> Map.fetch!(:compatibility)
  end

  defp codex_ollama_support_tier(requested_model) when is_binary(requested_model) do
    normalized_requested_model = normalize_external_model_name(requested_model)

    if normalized_requested_model in codex_ollama_validated_models() do
      "validated_default"
    else
      "runtime_validated_only"
    end
  end

  defp codex_ollama_validated_models do
    codex_ollama_compatibility()
    |> Map.get(:validated_models, [])
    |> Enum.map(&normalize_external_model_name/1)
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp ollama_opts(request) when is_list(request) do
    [
      anthropic_base_url: Keyword.get(request, :anthropic_base_url),
      ollama_base_url: Keyword.get(request, :ollama_base_url),
      ollama_http: Keyword.get(request, :ollama_http),
      ollama_timeout_ms: Keyword.get(request, :ollama_timeout_ms)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp ollama_opts(request) do
    [
      anthropic_base_url: request.anthropic_base_url,
      ollama_base_url: request.ollama_base_url,
      ollama_http: request.ollama_http,
      ollama_timeout_ms: request.ollama_timeout_ms
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp resolve_provider_backend(:claude, opts) when is_list(opts) do
    case normalize_backend_name(Keyword.get(opts, :provider_backend), "anthropic") do
      "anthropic" -> :anthropic
      "ollama" -> :ollama
      other -> String.to_atom(other)
    end
  end

  defp resolve_provider_backend(:codex, opts) when is_list(opts) do
    case normalize_backend_name(Keyword.get(opts, :provider_backend), "openai") do
      "openai" -> :openai
      "oss" -> :oss
      "model_provider" -> :model_provider
      other -> String.to_atom(other)
    end
  end

  defp resolve_provider_backend(_provider, _opts), do: nil

  defp ensure_ollama_responses_supported(provider, opts)
       when is_atom(provider) and is_list(opts) do
    case Ollama.fetch_version(opts) do
      {:ok, version} ->
        ensure_minimum_ollama_version(provider, version)

      {:error, reason} ->
        {:error, {:model_unavailable, provider, {:ollama_unavailable, reason}}}
    end
  end

  defp ensure_minimum_ollama_version(provider, version) when is_atom(provider) do
    case normalize_ollama_version(version) do
      nil ->
        {:ok, version}

      normalized_version ->
        if Version.compare(normalized_version, @ollama_min_responses_version) == :lt do
          {:error,
           {:model_unavailable, provider,
            {:ollama_version_unsupported, version, @ollama_min_responses_version}}}
        else
          {:ok, version}
        end
    end
  end

  defp normalize_ollama_version(nil), do: nil

  defp normalize_ollama_version(version) when is_binary(version) do
    version
    |> String.trim()
    |> String.trim_leading("v")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_backend_name(nil, default), do: default

  defp normalize_backend_name(value, default) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_backend_name(default)
  end

  defp normalize_backend_name(value, default) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> default
      normalized -> normalized
    end
  end

  defp normalize_external_codex_reasoning(nil), do: {:ok, "high"}

  defp normalize_external_codex_reasoning(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_external_codex_reasoning()
  end

  defp normalize_external_codex_reasoning(value) when is_binary(value) do
    normalized = String.trim(value) |> String.downcase()

    cond do
      normalized == "" ->
        {:ok, "high"}

      normalized in @invalid_model_inputs ->
        {:ok, "high"}

      normalized in @codex_external_reasonings ->
        {:ok, normalized}

      true ->
        {:error, @codex_external_reasonings}
    end
  end

  defp normalize_external_codex_reasoning(_other), do: {:error, @codex_external_reasonings}

  defp resolve_codex_oss_provider(provider, opts) when is_list(opts) do
    opts
    |> Keyword.get(:oss_provider, "ollama")
    |> normalize_optional_binary()
    |> case do
      nil ->
        {:error, {:model_unavailable, provider, :missing_oss_provider}}

      "ollama" ->
        {:ok, "ollama"}

      other ->
        {:error, {:model_unavailable, provider, {:unsupported_oss_provider, other}}}
    end
  end

  defp resolve_codex_oss_provider(provider, %{oss_provider: provider_name}) do
    resolve_codex_oss_provider(provider, oss_provider: provider_name)
  end

  defp resolve_codex_oss_provider(provider, _other), do: resolve_codex_oss_provider(provider, [])

  defp expand_visibility_filter(visibility) do
    case visibility do
      value when is_list(value) ->
        expand_visibility_list(value)

      value when is_atom(value) ->
        visibility_from_key(value)

      value when is_binary(value) ->
        value
        |> String.trim()
        |> String.downcase()
        |> visibility_key_from_string()
        |> visibility_from_key()

      _ ->
        {:error, {:model_unavailable, :unknown, :invalid_visibility}}
    end
  end

  defp expand_visibility_list(values) when is_list(values) do
    values
    |> Enum.reduce_while(MapSet.new(), fn visibility, acc ->
      case expand_visibility_filter(visibility) do
        {:ok, nested} ->
          {:cont, Enum.reduce(nested, acc, fn item, set -> MapSet.put(set, item) end)}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      %MapSet{} = set ->
        {:ok, MapSet.to_list(set)}

      {:error, _} = error ->
        error
    end
  end

  defp visibility_key_from_string("all"), do: :all
  defp visibility_key_from_string("public"), do: :public
  defp visibility_key_from_string("private"), do: :private
  defp visibility_key_from_string("internal"), do: :internal
  defp visibility_key_from_string("restricted"), do: :restricted
  defp visibility_key_from_string("default"), do: :default
  defp visibility_key_from_string(_other), do: :invalid

  defp visibility_from_key(key) when is_atom(key) do
    case Map.fetch(@visibility_filters, key) do
      {:ok, filters} -> {:ok, filters}
      :error -> {:error, {:model_unavailable, :unknown, :invalid_visibility}}
    end
  end

  defp default_model_from_catalog(catalog, provider) do
    catalog.models
    |> Enum.find(& &1.default)
    |> case do
      nil -> {:error, {:model_unavailable, provider, :no_provider_default}}
      %Model{} = model -> {:ok, model}
    end
  end

  defp normalize_optional_binary(nil), do: nil

  defp normalize_optional_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_binary(_other), do: nil

  defp normalize_provider(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> String.to_atom()

  defp normalize_provider(provider) when is_binary(provider),
    do: provider |> String.trim() |> String.downcase() |> String.to_atom()
end
