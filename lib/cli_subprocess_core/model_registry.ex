defmodule CliSubprocessCore.ModelRegistry do
  @moduledoc "Canonical model resolution, validation, and argument payload construction."

  alias CliSubprocessCore.ModelCatalog
  alias CliSubprocessCore.ModelRegistry.{Model, Selection}

  @type resolution_error ::
          {:unknown_model, String.t() | nil, [String.t()], atom()}
          | {:invalid_reasoning_effort, term(), [String.t()] | [number()], atom()}
          | {:model_unavailable, atom(), term()}
          | {:empty_or_invalid_model, String.t(), atom()}

  @type selection :: Selection.t()
  @type model :: Model.t()

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

    with {:ok, catalog} <- load_catalog(provider),
         {:ok, candidate, source, payload_requested} <-
           pick_request_source(catalog, requested_model, opts, provider),
         {:ok, model} <- find_model(catalog.models, candidate, provider),
         {:ok, reasoning_payload} <- resolve_reasoning_payload(model, provider, opts) do
      {:ok,
       Selection.new(%{
         provider: provider,
         requested_model: payload_requested,
         resolved_model: model.id,
         resolution_source: source,
         reasoning: reasoning_payload.reasoning,
         reasoning_effort: reasoning_payload.reasoning_effort,
         normalized_reasoning_effort: reasoning_payload.normalized_reasoning_effort,
         model_family: model.family,
         catalog_version: catalog.catalog_version,
         visibility: model.visibility,
         errors: []
       })}
    end
  end

  @spec list_visible(atom(), keyword()) ::
          {:ok, [String.t()]} | {:error, {:model_unavailable, atom(), term()}}
  def list_visible(provider, opts \\ []) when is_list(opts) do
    provider = normalize_provider(provider)
    visibility = Keyword.get(opts, :visibility, :public)
    family = normalize_optional_binary(Keyword.get(opts, :model_family))

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

  @spec default_model(atom(), keyword()) ::
          {:ok, String.t()} | {:error, {:model_unavailable, atom(), term()}}
  def default_model(provider, opts \\ []) when is_list(opts) do
    provider = normalize_provider(provider)

    with {:ok, catalog} <- load_catalog(provider) do
      case default_model_from_catalog(catalog, provider) do
        {:ok, model} -> {:ok, model.id}
        {:error, _reason} -> catalog_remote_default(catalog, provider)
      end
    end
  end

  @spec validate(atom(), String.t() | nil) ::
          {:ok, Model.t()} | {:error, resolution_error()}
  def validate(provider, requested_model)
      when is_binary(requested_model) or is_atom(requested_model) do
    provider = normalize_provider(provider)

    with {:ok, catalog} <- load_catalog(provider),
         {:ok, normalized_requested} <-
           normalize_requested_model(requested_model, :explicit, provider) do
      find_model(catalog.models, normalized_requested, provider)
    end
  end

  def validate(provider, nil) do
    {:error,
     {:empty_or_invalid_model, "requested model is missing", normalize_provider(provider)}}
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

  defp pick_request_source(catalog, requested_model, opts, provider) do
    case normalize_requested_model_maybe(requested_model, :explicit, provider) do
      {:ok, candidate} ->
        {:ok, candidate, :explicit, candidate}

      {:skip} ->
        pick_env_or_default(catalog, env_model_from_opts(opts), provider)

      {:error, _} = error ->
        error
    end
  end

  defp pick_env_or_default(catalog, env_model, provider) do
    case normalize_requested_model_maybe(env_model, :env, provider) do
      {:ok, candidate} ->
        {:ok, candidate, :env, candidate}

      {:skip} ->
        pick_default_or_remote(catalog, provider)

      {:error, _} = error ->
        error
    end
  end

  defp pick_default_or_remote(catalog, provider) do
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
