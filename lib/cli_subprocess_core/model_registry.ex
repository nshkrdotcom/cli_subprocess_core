defmodule CliSubprocessCore.ModelRegistry do
  @moduledoc "Canonical model resolution, validation, and argument payload construction."

  alias CliSubprocessCore.ModelCatalog
  alias CliSubprocessCore.ModelRegistry.{Model, Selection}
  alias CliSubprocessCore.Ollama

  @type resolution_error ::
          {:unknown_model, String.t() | nil, [String.t()], atom()}
          | {:invalid_reasoning_effort, term(), [String.t()] | [number()], atom()}
          | {:model_unavailable, atom(), term()}
          | {:empty_or_invalid_model, String.t(), atom()}

  @type selection :: Selection.t()
  @type model :: Model.t()
  @type provider_backend :: :anthropic | :ollama | atom()

  @invalid_model_inputs ["", "nil", "null"]
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
      external_model_overrides: Keyword.get(opts, :external_model_overrides, %{}),
      anthropic_base_url: Keyword.get(opts, :anthropic_base_url),
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
      external_model_overrides:
        Map.get(
          request,
          :external_model_overrides,
          Map.get(request, "external_model_overrides", %{})
        ),
      anthropic_base_url:
        Map.get(request, :anthropic_base_url, Map.get(request, "anthropic_base_url")),
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

  defp ollama_model_family(details) when is_map(details) do
    details
    |> Map.get("details", %{})
    |> Map.get("family")
  end

  defp ollama_opts(request) do
    [
      anthropic_base_url: request.anthropic_base_url,
      ollama_http: request.ollama_http,
      ollama_timeout_ms: request.ollama_timeout_ms
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp resolve_provider_backend(:claude, opts) when is_list(opts) do
    case Keyword.get(opts, :provider_backend, :anthropic) do
      nil ->
        :anthropic

      :anthropic ->
        :anthropic

      "anthropic" ->
        :anthropic

      :ollama ->
        :ollama

      "ollama" ->
        :ollama

      other when is_atom(other) ->
        other

      other when is_binary(other) ->
        other |> String.trim() |> String.downcase() |> String.to_atom()
    end
  end

  defp resolve_provider_backend(_provider, _opts), do: nil

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
