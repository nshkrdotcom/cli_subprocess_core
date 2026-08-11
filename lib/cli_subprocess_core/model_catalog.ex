defmodule CliSubprocessCore.ModelCatalog do
  @moduledoc false

  alias CliSubprocessCore.ModelRegistry.Model

  @type catalog_error_reason ::
          :not_found
          | {:invalid_catalog, term()}
          | {:invalid_model, String.t(), term()}

  @type load_error :: {:model_unavailable, atom(), catalog_error_reason()}

  @type t :: %{
          provider: atom(),
          catalog_version: String.t(),
          remote_default: String.t() | nil,
          models: [Model.t()]
        }

  @catalog_filename_suffix ".json"
  @default_catalog_version "2026-03-25"
  @catalog_directory Path.expand("../../priv/models", __DIR__)
  @catalog_paths Path.wildcard(Path.join(@catalog_directory, "*#{@catalog_filename_suffix}"))

  for path <- @catalog_paths do
    @external_resource path
  end

  @embedded_catalogs Map.new(@catalog_paths, fn path ->
                       provider =
                         path
                         |> Path.basename(@catalog_filename_suffix)
                         |> String.to_existing_atom()

                       {provider, File.read!(path)}
                     end)

  @spec load(atom()) :: {:ok, t()} | {:error, load_error()}
  def load(provider) when is_atom(provider) do
    load_from_path(provider, catalog_path(provider))
  end

  @doc false
  @spec load_from_path(atom(), String.t()) :: {:ok, t()} | {:error, load_error()}
  def load_from_path(provider, path) when is_atom(provider) and is_binary(path) do
    with {:ok, body} <- read_catalog(path, provider),
         {:ok, payload} <- decode_catalog(body, provider),
         {:ok, models} <- decode_models(payload, provider) do
      {:ok,
       %{
         provider: provider,
         catalog_version: catalog_version(payload),
         remote_default: payload_get(payload, :remote_default),
         models: models
       }}
    end
  end

  @spec catalog_path(atom()) :: String.t()
  def catalog_path(provider) when is_atom(provider) do
    base = Path.join(Application.app_dir(:cli_subprocess_core), "priv")
    Path.join(base, "models/#{provider}#{@catalog_filename_suffix}")
  end

  defp read_catalog(path, provider) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, filesystem_reason} ->
        read_embedded_catalog(provider, filesystem_reason)
    end
  end

  defp read_embedded_catalog(provider, filesystem_reason) do
    case Map.fetch(@embedded_catalogs, provider) do
      {:ok, body} ->
        {:ok, body}

      :error ->
        {:error, {:model_unavailable, provider, {:not_found, filesystem_reason}}}
    end
  end

  defp decode_catalog(body, provider) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      {:ok, _payload} ->
        {:error, {:model_unavailable, provider, {:invalid_catalog, :payload_must_be_map}}}

      {:error, reason} ->
        {:error, {:model_unavailable, provider, {:invalid_catalog, reason}}}
    end
  end

  defp decode_models(payload, provider) do
    case payload_get(payload, :models) do
      models when is_list(models) ->
        load_models(models, provider)

      _other ->
        {:error, {:model_unavailable, provider, {:invalid_catalog, :missing_models}}}
    end
  end

  defp load_models(models, provider) when is_list(models) do
    models
    |> Enum.reduce_while({:ok, []}, fn model_attrs, {:ok, loaded} ->
      append_model(loaded, provider, model_attrs)
    end)
    |> finalize_loaded_models()
  end

  defp append_model(loaded, provider, model_attrs) do
    case Model.new(provider, model_attrs) do
      {:ok, model} ->
        {:cont, {:ok, [model | loaded]}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp finalize_loaded_models({:ok, models}), do: {:ok, Enum.reverse(models)}
  defp finalize_loaded_models({:error, reason}), do: {:error, reason}

  defp catalog_version(payload) do
    case payload_get(payload, :catalog_version) do
      nil -> @default_catalog_version
      version -> version
    end
  end

  defp payload_get(payload, key, default \\ nil) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key), default))
  end
end
