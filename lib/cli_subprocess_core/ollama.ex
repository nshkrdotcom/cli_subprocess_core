defmodule CliSubprocessCore.Ollama do
  @moduledoc """
  Ollama HTTP integration used by model validation and backend resolution.

  This module wraps the small set of Ollama endpoints the core runtime uses to
  verify availability, inspect installed models, and validate model ids.
  """

  @default_base_url "http://localhost:11434"
  @default_timeout_ms 5_000

  @type model_info :: map()
  @type http_stub ::
          (atom(), String.t(), map() | nil, keyword() ->
             {:ok, pos_integer(), map()} | {:error, term()})

  @spec list_models(keyword()) :: {:ok, [model_info()]} | {:error, term()}
  def list_models(opts \\ []) when is_list(opts) do
    case request(:get, "/api/tags", nil, opts) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok, models}

      {:ok, _other} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list_model_names(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_model_names(opts \\ []) when is_list(opts) do
    with {:ok, models} <- list_models(opts) do
      {:ok,
       models
       |> Enum.map(&model_name/1)
       |> Enum.reject(&is_nil/1)}
    end
  end

  @spec show_model(String.t(), keyword()) :: {:ok, model_info()} | {:error, term()}
  def show_model(model, opts \\ []) when is_binary(model) and is_list(opts) do
    request(:post, "/api/show", %{"model" => String.trim(model)}, opts)
  end

  @spec fetch_version(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch_version(opts \\ []) when is_list(opts) do
    case request(:get, "/api/version", nil, opts) do
      {:ok, %{"version" => version}} when is_binary(version) ->
        {:ok, String.trim(version)}

      {:ok, _other} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec validate_model(String.t(), atom(), keyword()) ::
          {:ok, model_info()}
          | {:error, {:unknown_model, String.t(), [String.t()], atom()}}
          | {:error, {:model_unavailable, atom(), {:ollama_unavailable, term()}}}
  def validate_model(model, provider, opts \\ [])
      when is_binary(model) and is_atom(provider) and is_list(opts) do
    model = String.trim(model)

    case show_model(model, opts) do
      {:ok, details} ->
        {:ok, details}

      {:error, {:http_error, 404, _body}} ->
        validate_model_alias(model, provider, opts)

      {:error, {:not_found, _body}} ->
        validate_model_alias(model, provider, opts)

      {:error, reason} ->
        {:error, {:model_unavailable, provider, {:ollama_unavailable, reason}}}
    end
  end

  @spec running_models(keyword()) :: {:ok, [model_info()]} | {:error, term()}
  def running_models(opts \\ []) when is_list(opts) do
    case request(:get, "/api/ps", nil, opts) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok, models}

      {:ok, _other} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec default_base_url() :: String.t()
  def default_base_url, do: @default_base_url

  @doc """
  Normalizes an Ollama base URL for Codex's OpenAI-compatible OSS route.

  Raw Ollama roots such as `http://localhost:11434` are promoted to `/v1`
  because current Codex CLI OSS requests target OpenAI-style endpoints below
  that prefix. Explicit non-root paths are preserved.
  """
  @spec codex_base_url(String.t() | nil) :: String.t() | nil
  def codex_base_url(nil), do: nil

  def codex_base_url(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        trimmed
        |> URI.parse()
        |> normalize_codex_base_uri()
        |> URI.to_string()
        |> String.trim_trailing("/")
    end
  end

  defp unknown_model_error(model, provider, opts) do
    suggestions =
      case list_model_names(opts) do
        {:ok, names} -> names
        {:error, _reason} -> []
      end

    {:error, {:unknown_model, model, suggestions, provider}}
  end

  defp validate_model_alias(model, provider, opts) do
    case alias_candidate(model, opts) do
      nil ->
        unknown_model_error(model, provider, opts)

      candidate ->
        case show_model(candidate, opts) do
          {:ok, details} -> {:ok, details}
          {:error, _reason} -> unknown_model_error(model, provider, opts)
        end
    end
  end

  defp alias_candidate(model, opts) do
    case list_model_names(opts) do
      {:ok, names} -> Enum.find(names, &same_model_name?(&1, model))
      {:error, _reason} -> nil
    end
  end

  defp same_model_name?(installed_name, requested_name)
       when is_binary(installed_name) and is_binary(requested_name) do
    normalize_model_name(installed_name) == normalize_model_name(requested_name)
  end

  defp normalize_model_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.trim_trailing(":latest")
  end

  defp request(method, path, payload, opts) when method in [:get, :post] and is_list(opts) do
    case Keyword.get(opts, :ollama_http) do
      http when is_function(http, 4) ->
        request_with_stub(http, method, path, payload, opts)

      nil ->
        request_with_httpc(method, path, payload, opts)
    end
  end

  defp request_with_stub(http, method, path, payload, opts) when is_function(http, 4) do
    case http.(method, path, payload, opts) do
      {:ok, status, body} when is_integer(status) and is_map(body) ->
        decode_stub_response(status, body)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_http_stub_response, other}}
    end
  end

  defp decode_stub_response(status, body) when status in 200..299, do: {:ok, body}
  defp decode_stub_response(404, body), do: {:error, {:not_found, body}}
  defp decode_stub_response(status, body), do: {:error, {:http_error, status, body}}

  defp request_with_httpc(method, path, payload, opts) do
    with :ok <- ensure_http_apps_started(),
         {:ok, body} <- do_httpc_request(method, path, payload, opts) do
      decode_http_body(body)
    end
  end

  defp ensure_http_apps_started do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok
    end
  end

  defp do_httpc_request(method, path, payload, opts) do
    url = String.to_charlist(base_url(opts) <> path)
    timeout = Keyword.get(opts, :ollama_timeout_ms, @default_timeout_ms)
    http_opts = [timeout: timeout]
    request_opts = [body_format: :binary]

    request =
      case method do
        :get ->
          {url, []}

        :post ->
          {url, [{~c"content-type", ~c"application/json"}], ~c"application/json",
           Jason.encode!(payload)}
      end

    case :httpc.request(method, request, http_opts, request_opts) do
      {:ok, {{_http_version, status, _reason_phrase}, _headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_http_version, 404, _reason_phrase}, _headers, body}} ->
        with {:ok, decoded} <- decode_http_body(body) do
          {:error, {:not_found, decoded}}
        end

      {:ok, {{_http_version, status, _reason_phrase}, _headers, body}} ->
        with {:ok, decoded} <- decode_http_body(body) do
          {:error, {:http_error, status, decoded}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_http_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, other} ->
        {:error, {:invalid_response, other}}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  defp base_url(opts) do
    opts
    |> Keyword.get(:anthropic_base_url, Keyword.get(opts, :ollama_base_url, @default_base_url))
    |> to_string()
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp normalize_codex_base_uri(%URI{} = uri) do
    %{uri | path: normalize_codex_base_path(uri.path)}
  end

  defp normalize_codex_base_path(nil), do: "/v1"

  defp normalize_codex_base_path(path) when is_binary(path) do
    case path |> String.trim() |> String.trim_trailing("/") do
      "" -> "/v1"
      "/v1" -> "/v1"
      other -> other
    end
  end

  defp model_name(model) when is_map(model) do
    Map.get(model, "name") || Map.get(model, "model")
  end
end
