defmodule CliSubprocessCore.ModelInput do
  @moduledoc """
  Normalizes mixed model input into one authoritative model payload.

  Callers may supply either raw model resolution knobs or a pre-resolved
  `CliSubprocessCore.ModelRegistry.Selection`. This module centralizes the
  arbitration and consistency rules so downstream layers can consume one
  canonical payload instead of re-resolving model policy locally.
  """

  alias CliSubprocessCore.{ModelRegistry, Ollama}
  alias CliSubprocessCore.ModelRegistry.Selection

  @raw_resolution_keys [
    :model,
    :reasoning,
    :reasoning_effort,
    :model_env,
    :env_model,
    :environment_model,
    :provider_backend,
    :model_provider,
    :oss_provider,
    :anthropic_base_url,
    :anthropic_auth_token,
    :ollama_base_url,
    :ollama_http,
    :ollama_timeout_ms,
    :external_model_overrides
  ]

  @string_raw_resolution_keys Enum.map(@raw_resolution_keys, &Atom.to_string/1)
  @payload_key_variants [:model_payload, "model_payload"]

  @type attrs :: keyword() | map()

  @type t :: %__MODULE__{
          provider: atom(),
          selection: Selection.t(),
          attrs: attrs()
        }

  @enforce_keys [:provider, :selection, :attrs]
  defstruct [:provider, :selection, :attrs]

  @doc """
  Normalizes model input for `provider`.

  Returns the authoritative `Selection` and normalized attrs/options with
  `:model_payload` attached and raw model-resolution keys removed.
  """
  @spec normalize(atom(), attrs()) :: {:ok, t()} | {:error, term()}
  def normalize(provider, attrs) when is_atom(provider) and (is_list(attrs) or is_map(attrs)) do
    normalize(provider, attrs, [])
  end

  @spec normalize(atom(), attrs(), keyword()) :: {:ok, t()} | {:error, term()}
  def normalize(provider, attrs, opts)
      when is_atom(provider) and (is_list(attrs) or is_map(attrs)) and is_list(opts) do
    provider = normalize_provider(provider)

    with {:ok, selection} <- resolve_selection(provider, attrs),
         normalized_attrs <- attach_selection(attrs, selection, opts) do
      {:ok, %__MODULE__{provider: provider, selection: selection, attrs: normalized_attrs}}
    end
  end

  defp resolve_selection(provider, attrs) do
    case fetch_attr(attrs, :model_payload) do
      nil ->
        resolve_selection_from_registry(provider, attrs)

      payload ->
        with {:ok, normalized_payload} <- normalize_supplied_payload(provider, payload),
             :ok <- validate_payload_consistency(provider, normalized_payload, attrs) do
          {:ok, normalized_payload}
        end
    end
  end

  defp resolve_selection_from_registry(provider, attrs) do
    requested_model = fetch_attr(attrs, :model)

    registry_opts =
      []
      |> maybe_put(:model_env, fetch_attr(attrs, :model_env))
      |> maybe_put(:env_model, fetch_attr(attrs, :env_model))
      |> maybe_put(:environment_model, fetch_attr(attrs, :environment_model))
      |> maybe_put(:provider_backend, fetch_attr(attrs, :provider_backend))
      |> maybe_put(:model_provider, fetch_attr(attrs, :model_provider))
      |> maybe_put(:oss_provider, fetch_attr(attrs, :oss_provider))
      |> maybe_put(:anthropic_base_url, fetch_attr(attrs, :anthropic_base_url))
      |> maybe_put(:anthropic_auth_token, fetch_attr(attrs, :anthropic_auth_token))
      |> maybe_put(:ollama_base_url, fetch_attr(attrs, :ollama_base_url))
      |> maybe_put(:ollama_http, fetch_attr(attrs, :ollama_http))
      |> maybe_put(:ollama_timeout_ms, fetch_attr(attrs, :ollama_timeout_ms))
      |> maybe_put(:external_model_overrides, fetch_attr(attrs, :external_model_overrides))
      |> maybe_put_reasoning(
        fetch_attr(attrs, :reasoning_effort) || fetch_attr(attrs, :reasoning)
      )

    ModelRegistry.build_arg_payload(provider, requested_model, registry_opts)
  end

  defp normalize_supplied_payload(provider, %Selection{} = payload) do
    payload
    |> normalize_selection_payload()
    |> validate_supplied_payload(provider)
  end

  defp normalize_supplied_payload(provider, payload) when is_map(payload) or is_list(payload) do
    payload
    |> Selection.new()
    |> normalize_selection_payload()
    |> validate_supplied_payload(provider)
  end

  defp normalize_supplied_payload(_provider, other), do: {:error, {:invalid_model_payload, other}}

  defp normalize_selection_payload(%Selection{} = payload) do
    payload
    |> Map.from_struct()
    |> Map.put(:provider, normalize_provider(fetch_map_value(payload, :provider)))
    |> Map.put(:provider_backend, normalize_backend(fetch_map_value(payload, :provider_backend)))
    |> Map.put(:env_overrides, normalize_map(fetch_map_value(payload, :env_overrides)))
    |> Map.put(:settings_patch, normalize_map(fetch_map_value(payload, :settings_patch)))
    |> Map.put(:backend_metadata, normalize_map(fetch_map_value(payload, :backend_metadata)))
    |> Selection.new()
  end

  defp validate_supplied_payload(%Selection{} = payload, provider) do
    cond do
      payload.provider not in [nil, provider] ->
        {:error, {:invalid_model_payload_provider, payload.provider}}

      not is_binary(payload.resolved_model) or payload.resolved_model == "" ->
        {:error, {:invalid_model_payload, :missing_resolved_model}}

      true ->
        {:ok,
         if(payload.provider == provider,
           do: payload,
           else: payload |> Selection.to_map() |> Map.put(:provider, provider) |> Selection.new()
         )}
    end
  end

  defp validate_payload_consistency(provider, %Selection{} = payload, attrs) do
    with :ok <- validate_model_consistency(payload, attrs),
         :ok <- validate_backend_consistency(payload, attrs),
         :ok <- validate_model_provider_consistency(payload, attrs),
         :ok <- validate_oss_provider_consistency(payload, attrs),
         :ok <- validate_reasoning_consistency(payload, attrs) do
      validate_provider_transport_consistency(provider, payload, attrs)
    end
  end

  defp validate_model_consistency(%Selection{} = payload, attrs) do
    case fetch_attr(attrs, :model) |> normalize_string() do
      nil ->
        :ok

      supplied_model ->
        acceptable_models =
          [payload.requested_model, payload.resolved_model]
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.uniq()

        if supplied_model in acceptable_models do
          :ok
        else
          {:error,
           {:model_payload_conflict, :model, List.first(acceptable_models), supplied_model}}
        end
    end
  end

  defp validate_backend_consistency(%Selection{} = payload, attrs) do
    case fetch_attr(attrs, :provider_backend) |> normalize_backend() do
      nil ->
        :ok

      supplied_backend ->
        if supplied_backend == payload.provider_backend do
          :ok
        else
          {:error,
           {:model_payload_conflict, :provider_backend, payload.provider_backend,
            supplied_backend}}
        end
    end
  end

  defp validate_model_provider_consistency(%Selection{} = payload, attrs) do
    case fetch_attr(attrs, :model_provider) |> normalize_string() do
      nil ->
        :ok

      supplied_model_provider ->
        expected_model_provider = payload_metadata(payload, "model_provider")

        if supplied_model_provider == expected_model_provider do
          :ok
        else
          {:error,
           {:model_payload_conflict, :model_provider, expected_model_provider,
            supplied_model_provider}}
        end
    end
  end

  defp validate_oss_provider_consistency(%Selection{} = payload, attrs) do
    case fetch_attr(attrs, :oss_provider) |> normalize_string() do
      nil ->
        :ok

      supplied_oss_provider ->
        expected_oss_provider = payload_metadata(payload, "oss_provider")

        if supplied_oss_provider == expected_oss_provider do
          :ok
        else
          {:error,
           {:model_payload_conflict, :oss_provider, expected_oss_provider, supplied_oss_provider}}
        end
    end
  end

  defp validate_reasoning_consistency(%Selection{} = payload, attrs) do
    case fetch_attr(attrs, :reasoning_effort) || fetch_attr(attrs, :reasoning) do
      nil ->
        :ok

      supplied_reasoning ->
        normalized_supplied_reasoning = normalize_reasoning_value(supplied_reasoning)
        expected_reasoning = normalize_reasoning_value(payload.reasoning)

        if normalized_supplied_reasoning == expected_reasoning do
          :ok
        else
          {:error,
           {:model_payload_conflict, :reasoning_effort, expected_reasoning,
            normalized_supplied_reasoning}}
        end
    end
  end

  defp validate_provider_transport_consistency(:claude, %Selection{} = payload, attrs) do
    with :ok <-
           validate_env_override_consistency(
             payload,
             attrs,
             :anthropic_base_url,
             "ANTHROPIC_BASE_URL"
           ) do
      validate_env_override_consistency(
        payload,
        attrs,
        :anthropic_auth_token,
        "ANTHROPIC_AUTH_TOKEN"
      )
    end
  end

  defp validate_provider_transport_consistency(:codex, %Selection{} = payload, attrs) do
    validate_env_override_consistency(payload, attrs, :ollama_base_url, "CODEX_OSS_BASE_URL")
  end

  defp validate_provider_transport_consistency(_provider, _payload, _attrs), do: :ok

  defp validate_env_override_consistency(%Selection{} = payload, attrs, attr_key, env_key) do
    case normalize_transport_attr_value(attr_key, env_key, fetch_attr(attrs, attr_key)) do
      nil ->
        :ok

      supplied_value ->
        expected_value = payload_env_override(payload, env_key)

        if supplied_value == expected_value do
          :ok
        else
          {:error, {:model_payload_conflict, attr_key, expected_value, supplied_value}}
        end
    end
  end

  defp normalize_transport_attr_value(:ollama_base_url, "CODEX_OSS_BASE_URL", value) do
    case normalize_string(value) do
      nil -> nil
      normalized -> Ollama.codex_base_url(normalized)
    end
  end

  defp normalize_transport_attr_value(_attr_key, _env_key, value), do: normalize_string(value)

  defp attach_selection(attrs, %Selection{} = selection, opts) when is_list(attrs) do
    strip_keys = Keyword.get(opts, :strip_keys, [])
    strip_key_variants = strip_key_variants(strip_keys)

    normalized_attrs =
      attrs
      |> Enum.reject(fn
        {key, _value} ->
          key in @payload_key_variants or key in @raw_resolution_keys or
            key in @string_raw_resolution_keys or key in strip_key_variants

        _other ->
          false
      end)
      |> Keyword.put(:model_payload, selection)

    normalized_attrs
  end

  defp attach_selection(attrs, %Selection{} = selection, opts) when is_map(attrs) do
    strip_keys = Keyword.get(opts, :strip_keys, [])

    attrs
    |> Map.drop(
      @payload_key_variants ++
        @raw_resolution_keys ++ @string_raw_resolution_keys ++ strip_key_variants(strip_keys)
    )
    |> Map.put(:model_payload, selection)
  end

  defp strip_key_variants(keys) when is_list(keys) do
    Enum.flat_map(keys, fn
      key when is_atom(key) -> [key, Atom.to_string(key)]
      key when is_binary(key) -> [key]
      _other -> []
    end)
  end

  defp payload_env_override(%Selection{} = payload, key) when is_binary(key) do
    payload.env_overrides
    |> fetch_string_or_known_atom(key)
    |> normalize_string()
  end

  defp payload_metadata(%Selection{} = payload, key) when is_binary(key) do
    payload.backend_metadata
    |> fetch_string_or_known_atom(key)
    |> normalize_string()
  end

  defp fetch_map_value(%Selection{} = payload, key) when is_atom(key) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
  end

  defp fetch_attr(attrs, key) when is_atom(key) and is_list(attrs) do
    case List.keyfind(attrs, key, 0) do
      {^key, value} ->
        value

      nil ->
        string_key = Atom.to_string(key)

        case List.keyfind(attrs, string_key, 0) do
          {^string_key, value} -> value
          nil -> nil
        end
    end
  end

  defp fetch_attr(attrs, key) when is_atom(key) and is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_reasoning(opts, nil), do: opts
  defp maybe_put_reasoning(opts, reasoning), do: Keyword.put(opts, :reasoning_effort, reasoning)

  defp normalize_provider(nil), do: nil
  defp normalize_provider(value) when value in [:claude, :gemini, :amp, :codex], do: value
  defp normalize_provider("claude"), do: :claude
  defp normalize_provider("gemini"), do: :gemini
  defp normalize_provider("amp"), do: :amp
  defp normalize_provider("codex"), do: :codex
  defp normalize_provider(other), do: other

  defp normalize_backend(nil), do: nil

  defp normalize_backend(value)
       when value in [:anthropic, :ollama, :openai, :oss, :model_provider],
       do: value

  defp normalize_backend(value) when is_binary(value) do
    case String.trim(value) do
      "anthropic" -> :anthropic
      "ollama" -> :ollama
      "openai" -> :openai
      "oss" -> :oss
      "model_provider" -> :model_provider
      other -> other
    end
  end

  defp normalize_backend(other), do: other

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_other), do: %{}

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(value) when is_number(value), do: to_string(value)
  defp normalize_string(value) when is_boolean(value), do: to_string(value)
  defp normalize_string(_other), do: nil

  defp normalize_reasoning_value(nil), do: nil
  defp normalize_reasoning_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_reasoning_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_reasoning_value(value), do: value

  defp fetch_string_or_known_atom(map, key) when is_map(map) and is_binary(key) do
    case known_atom_key(key) do
      nil -> Map.get(map, key)
      known_atom -> Map.get(map, key, Map.get(map, known_atom))
    end
  end

  defp known_atom_key("model_provider"), do: :model_provider
  defp known_atom_key("oss_provider"), do: :oss_provider
  defp known_atom_key("ANTHROPIC_BASE_URL"), do: :ANTHROPIC_BASE_URL
  defp known_atom_key("ANTHROPIC_AUTH_TOKEN"), do: :ANTHROPIC_AUTH_TOKEN
  defp known_atom_key("CODEX_OSS_BASE_URL"), do: :CODEX_OSS_BASE_URL
  defp known_atom_key(_key), do: nil
end
